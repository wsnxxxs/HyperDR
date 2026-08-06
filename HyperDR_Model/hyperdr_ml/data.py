from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Literal

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import Dataset

from hyperdr_ml.geometry import MODEL_STRIDE

Split = Literal["train", "validation", "test"]
LabelSubset = Literal["all", "iso_native", "legacy_apple", "xmp"]
TargetMode = Literal["per_image", "fixed_3stops"]
FIXED_GAIN_STOPS = 3.0


def _finite_positive(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and number > 0.0


class AppleGainMapDataset(Dataset):
    def __init__(
        self,
        root: str | Path,
        split: Split,
        label_subset: LabelSubset = "all",
        augment: bool = False,
        target_mode: TargetMode = "fixed_3stops",
        allow_legacy_label_schema: bool = False,
    ) -> None:
        self.root = Path(root)
        split_ids = json.loads((self.root / "splits" / f"{split}.json").read_text())["sample_ids"]
        manifest = {
            row["sample_id"]: row
            for row in (
                json.loads(line)
                for line in (self.root / "manifests" / "samples.jsonl").read_text().splitlines()
            )
        }
        # A Phase A corpus lock makes the old normalized/f16 labels an
        # explicit compatibility mode.  Small v1 unit fixtures do not carry a
        # lock and remain usable for regression tests.
        lock_path = self.root / "reports" / "phase-a-corpus-lock.json"
        if lock_path.exists() and not allow_legacy_label_schema:
            raise ValueError(
                "dataset is locked to hyperdr.apple-gain-label/v2; "
                "pass allow_legacy_label_schema=True only to reproduce v1"
            )
        if label_subset not in {"all", "iso_native", "legacy_apple", "xmp"}:
            raise ValueError(f"unknown label_subset={label_subset!r}")
        if label_subset == "xmp":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if manifest[sample_id]["headroom_source"] == "xmp_hdr_gain_map_headroom"
            ]
        elif label_subset == "iso_native":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if int(manifest[sample_id].get("gain_map_version") or 0) == 131072
                or manifest[sample_id].get("phase_a_source_type") == "iso_21496_1_tmap"
            ]
        elif label_subset == "legacy_apple":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if int(manifest[sample_id].get("gain_map_version") or 0) == 65536
                or manifest[sample_id].get("phase_a_source_type") == "legacy_apple"
            ]
        if target_mode == "per_image":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if _finite_positive(manifest[sample_id].get("canonical_max_log2_gain"))
            ]
        self.rows = [manifest[sample_id] for sample_id in split_ids]
        self.augment = augment
        self.target_mode = target_mode

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor | str]:
        row = self.rows[index]
        sample_id = row["sample_id"]
        sdr = torch.from_numpy(
            np.load(self.root / "training" / "linear_p3_f16" / f"{sample_id}.npy", allow_pickle=False)
            .astype(np.float32)
        )
        gain = torch.from_numpy(
            np.load(
                self.root / "training" / "gain_grid_stride16_f16" / f"{sample_id}.npy",
                allow_pickle=False,
            ).astype(np.float32)
        )
        _validate_spatial_sample(sample_id, sdr, gain)
        if not torch.isfinite(sdr).all() or not torch.isfinite(gain).all():
            raise ValueError(f"Non-finite cached tensor for sample {sample_id}")
        if self.augment and bool(torch.rand(()) < 0.5):
            sdr = torch.flip(sdr, dims=(-1,))
            gain = torch.flip(gain, dims=(-1,))
        max_log2_gain = float(row["canonical_max_log2_gain"])
        if not math.isfinite(max_log2_gain) or max_log2_gain < 0.0:
            raise ValueError(f"Invalid max_log2_gain={max_log2_gain!r} for {sample_id}")
        if self.target_mode == "per_image" and max_log2_gain <= 0.0:
            raise ValueError(
                f"per_image target requires finite max_log2_gain > 0 for {sample_id}"
            )
        target_scale = (
            max_log2_gain if self.target_mode == "per_image" else FIXED_GAIN_STOPS
        )
        normalized_gain = gain / target_scale
        if not torch.isfinite(normalized_gain).all():
            raise ValueError(f"Non-finite normalized target for sample {sample_id}")
        saturated = normalized_gain > 1.0
        return {
            "sample_id": sample_id,
            "sdr": sdr,
            "target": normalized_gain.clamp(0.0, 1.0),
            "max_log2_gain": torch.tensor(max_log2_gain, dtype=torch.float32),
            "saturated_pixel_fraction": saturated.float().mean(),
        }


def _validate_spatial_sample(
    sample_id: str, sdr: torch.Tensor, target: torch.Tensor
) -> None:
    if sdr.ndim != 3 or sdr.shape[0] != 3:
        raise ValueError(f"{sample_id}: expected SDR shape 3HW, got {tuple(sdr.shape)}")
    if target.ndim != 3 or target.shape[0] != 1:
        raise ValueError(
            f"{sample_id}: expected target shape 1HW, got {tuple(target.shape)}"
        )
    height, width = (int(value) for value in sdr.shape[-2:])
    if height % MODEL_STRIDE or width % MODEL_STRIDE:
        raise ValueError(
            f"{sample_id}: SDR dimensions must be divisible by {MODEL_STRIDE}, "
            f"got {(height, width)}"
        )
    expected = (height // MODEL_STRIDE, width // MODEL_STRIDE)
    if tuple(target.shape[-2:]) != expected:
        raise ValueError(
            f"{sample_id}: target shape {tuple(target.shape[-2:])} does not match "
            f"SDR stride-{MODEL_STRIDE} grid {expected}"
        )


def collate_gain_maps(samples: list[dict[str, torch.Tensor | str]]) -> dict[str, torch.Tensor | list[str]]:
    if not samples:
        raise ValueError("Cannot collate an empty sample list")
    for sample in samples:
        _validate_spatial_sample(
            str(sample["sample_id"]),
            sample["sdr"],
            sample["target"],
        )
        if not torch.isfinite(sample["sdr"]).all() or not torch.isfinite(
            sample["target"]
        ).all():
            raise ValueError(f"Non-finite batch tensor for {sample['sample_id']}")
    max_height = max(int(sample["sdr"].shape[-2]) for sample in samples)
    max_width = max(int(sample["sdr"].shape[-1]) for sample in samples)
    batch_sdr = []
    batch_target = []
    batch_mask = []
    for sample in samples:
        sdr = sample["sdr"]
        target = sample["target"]
        height, width = sdr.shape[-2:]
        pad_height = max_height - height
        pad_width = max_width - width
        batch_sdr.append(F.pad(sdr, (0, pad_width, 0, pad_height), mode="constant", value=0.0))
        batch_target.append(
            F.pad(
                target,
                (
                    0,
                    pad_width // MODEL_STRIDE,
                    0,
                    pad_height // MODEL_STRIDE,
                ),
                value=0.0,
            )
        )
        mask = torch.ones_like(target)
        batch_mask.append(
            F.pad(
                mask,
                (
                    0,
                    pad_width // MODEL_STRIDE,
                    0,
                    pad_height // MODEL_STRIDE,
                ),
                value=0.0,
            )
        )
    return {
        "sample_id": [str(sample["sample_id"]) for sample in samples],
        "sdr": torch.stack(batch_sdr),
        "target": torch.stack(batch_target),
        "mask": torch.stack(batch_mask),
        "max_log2_gain": torch.stack([sample["max_log2_gain"] for sample in samples]),
        "saturated_pixel_fraction": torch.stack(
            [sample["saturated_pixel_fraction"] for sample in samples]
        ),
    }


def target_statistics(dataset: AppleGainMapDataset) -> dict[str, float | int | str]:
    """Scan cached gain grids without loading SDR tensors."""
    target_sum = 0.0
    pixel_count = 0
    saturated_pixels = 0
    saturated_samples = 0
    declared_max_above_fixed_scale = 0
    for row in dataset.rows:
        sample_id = row["sample_id"]
        gain = np.load(
            dataset.root
            / "training"
            / "gain_grid_stride16_f16"
            / f"{sample_id}.npy",
            allow_pickle=False,
        ).astype(np.float32)
        max_log2_gain = float(row["canonical_max_log2_gain"])
        declared_max_above_fixed_scale += int(
            max_log2_gain > FIXED_GAIN_STOPS
        )
        scale = (
            max_log2_gain
            if dataset.target_mode == "per_image"
            else FIXED_GAIN_STOPS
        )
        if not math.isfinite(scale) or scale <= 0.0:
            raise ValueError(f"Invalid target scale={scale!r} for {sample_id}")
        normalized = gain / scale
        if not np.isfinite(normalized).all():
            raise ValueError(f"Non-finite target while scanning {sample_id}")
        saturated = normalized > 1.0
        saturated_count = int(saturated.sum())
        saturated_pixels += saturated_count
        saturated_samples += int(saturated_count > 0)
        target_sum += float(np.clip(normalized, 0.0, 1.0).sum(dtype=np.float64))
        pixel_count += int(normalized.size)
    return {
        "target_mode": dataset.target_mode,
        "samples": len(dataset),
        "pixels": pixel_count,
        "masked_target_mean": target_sum / pixel_count if pixel_count else 0.0,
        "saturated_samples": saturated_samples,
        "saturated_sample_fraction": (
            saturated_samples / len(dataset) if len(dataset) else 0.0
        ),
        "declared_max_above_3_stops_samples": declared_max_above_fixed_scale,
        "declared_max_above_3_stops_sample_fraction": (
            declared_max_above_fixed_scale / len(dataset)
            if len(dataset)
            else 0.0
        ),
        "saturated_pixels": saturated_pixels,
        "saturated_pixel_fraction": (
            saturated_pixels / pixel_count if pixel_count else 0.0
        ),
    }
