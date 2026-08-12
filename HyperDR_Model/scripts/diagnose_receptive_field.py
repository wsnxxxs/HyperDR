#!/usr/bin/env python3
"""Low-cost validation diagnostics for missing whole-image context."""

from __future__ import annotations

import argparse
from contextlib import nullcontext
import json
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.utils.data import DataLoader

from hyperdr_ml.data import (
    FIXED_GAIN_STOPS,
    AppleGainMapDataset,
    collate_gain_maps,
)
from hyperdr_ml.model import DirectGainMapNet
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast("cuda", dtype=torch.bfloat16)
    return nullcontext()


def ranks(values: np.ndarray) -> np.ndarray:
    order = np.argsort(values, kind="mergesort")
    result = np.empty(len(values), dtype=np.float64)
    result[order] = np.arange(len(values), dtype=np.float64)
    return result


def correlation(left: list[float], right: list[float]) -> dict[str, float | int | None]:
    pairs = np.asarray(
        [
            (a, b)
            for a, b in zip(left, right)
            if np.isfinite(a) and np.isfinite(b)
        ],
        dtype=np.float64,
    )
    if len(pairs) < 3 or np.ptp(pairs[:, 0]) == 0 or np.ptp(pairs[:, 1]) == 0:
        return {"samples": int(len(pairs)), "pearson": None, "spearman": None}
    return {
        "samples": int(len(pairs)),
        "pearson": float(np.corrcoef(pairs[:, 0], pairs[:, 1])[0, 1]),
        "spearman": float(
            np.corrcoef(ranks(pairs[:, 0]), ranks(pairs[:, 1]))[0, 1]
        ),
    }


def quartile_buckets(
    rows: list[dict[str, Any]], field: str
) -> list[dict[str, float | int | None]]:
    finite = [row for row in rows if np.isfinite(row[field])]
    if not finite:
        return []
    boundaries = np.quantile([row[field] for row in finite], [0.0, 0.25, 0.5, 0.75, 1.0])
    result = []
    for index in range(4):
        lower = float(boundaries[index])
        upper = float(boundaries[index + 1])
        selected = [
            row
            for row in finite
            if row[field] >= lower
            and (row[field] <= upper if index == 3 else row[field] < upper)
        ]
        result.append(
            {
                "quartile": index + 1,
                "lower": lower,
                "upper": upper,
                "samples": len(selected),
                "mean_residual": (
                    float(np.mean([row["mean_residual"] for row in selected]))
                    if selected
                    else None
                ),
                "mean_absolute_residual": (
                    float(
                        np.mean(
                            [abs(row["mean_residual"]) for row in selected]
                        )
                    )
                    if selected
                    else None
                ),
            }
        )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--split", choices=("train", "validation", "test"), default="validation"
    )
    parser.add_argument("--allow-test", action="store_true")
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument("--allow-legacy-label-schema", action="store_true")
    args = parser.parse_args()
    if args.split == "test" and not args.allow_test:
        raise SystemExit("Refusing to inspect test without explicit --allow-test")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda was requested but CUDA is unavailable")
    device = torch.device(
        "cuda"
        if args.device == "cuda"
        or (args.device == "auto" and torch.cuda.is_available())
        else "cpu"
    )

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    expected_contract = "hyperdr.apple-gain-label/v1" if args.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise SystemExit("checkpoint label contract is not permitted by the schema gate")
    if "manifest_sha256" in checkpoint and checkpoint.get("manifest_sha256") != sha256_file(
        Path(config["dataset_root"]) / "manifests" / "samples.jsonl"
    ):
        raise SystemExit("checkpoint manifest hash does not match the dataset")
    dataset = AppleGainMapDataset(
        config["dataset_root"],
        args.split,
        config["label_subset"],
        False,
        config["target_mode"],
        allow_legacy_label_schema=args.allow_legacy_label_schema,
    )
    loader = DataLoader(
        dataset, batch_size=8, num_workers=4, collate_fn=collate_gain_maps
    )
    manifest = {
        row["sample_id"]: row
        for row in (
            json.loads(line)
            for line in (
                Path(config["dataset_root"]) / "manifests" / "samples.jsonl"
            )
            .read_text()
            .splitlines()
        )
    }
    model = DirectGainMapNet(
        config["base_channels"], config.get("architecture", "baseline")
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    scale = (
        FIXED_GAIN_STOPS if config["target_mode"] == "fixed_3stops" else 1.0
    )

    rows = []
    with torch.inference_mode():
        for batch in loader:
            with autocast_context(device):
                prediction = model(batch["sdr"].to(device)).float().cpu()
            for index, sample_id in enumerate(batch["sample_id"]):
                valid = batch["mask"][index].bool()
                expected = batch["target"][index][valid]
                predicted = prediction[index][valid]
                valid_grid = batch["mask"][index, 0].bool()
                source_height = int(valid_grid.any(dim=1).sum()) * 16
                source_width = int(valid_grid.any(dim=0).sum()) * 16
                source = batch["sdr"][
                    index, :, :source_height, :source_width
                ]
                luminance = (
                    0.22897456 * source[0]
                    + 0.69173852 * source[1]
                    + 0.07928691 * source[2]
                )
                metadata = manifest[sample_id]
                rows.append(
                    {
                        "sample_id": sample_id,
                        "mean_residual": float(
                            (predicted.mean() - expected.mean()) * scale
                        ),
                        "mean_linear_brightness": float(luminance.mean()),
                        "mean_log2_brightness": float(
                            torch.log2(luminance.clamp_min(1e-6)).mean()
                        ),
                        "exposure_seconds": float(
                            metadata.get("exposure_seconds") or np.nan
                        ),
                        "iso": float(metadata.get("iso") or np.nan),
                        "exposure_bias_ev": float(
                            metadata.get("exposure_bias_ev")
                            if metadata.get("exposure_bias_ev") is not None
                            else np.nan
                        ),
                    }
                )

    residuals = [row["mean_residual"] for row in rows]
    fields = (
        "mean_linear_brightness",
        "mean_log2_brightness",
        "exposure_seconds",
        "iso",
        "exposure_bias_ev",
    )
    result = {
        "checkpoint": str(args.checkpoint),
        "checkpoint_epoch": checkpoint["epoch"],
        "architecture": config.get("architecture", "baseline"),
        "split": args.split,
        "test_accessed": args.split == "test",
        "residual_unit": (
            "stops"
            if config["target_mode"] == "fixed_3stops"
            else "relative normalized gain"
        ),
        "samples": len(rows),
        "mean_residual": float(np.mean(residuals)),
        "mean_absolute_residual": float(np.mean(np.abs(residuals))),
        "correlations": {
            field: correlation(
                [row[field] for row in rows],
                residuals,
            )
            for field in fields
        },
        "buckets": {
            field: quartile_buckets(rows, field)
            for field in fields
        },
        "scene_category": {
            "available": False,
            "reason": "The current manifest has no independently labeled scene category.",
        },
        "per_sample": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {key: value for key, value in result.items() if key != "per_sample"},
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
