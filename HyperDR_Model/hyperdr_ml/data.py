from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Literal

import numpy as np
import torch
import torch.nn.functional as F
from torch.utils.data import Dataset, Sampler

from hyperdr_ml.geometry import MODEL_STRIDE, target_grid_size
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID
from hyperdr_ml.provenance import ProvenanceLedger

Split = Literal["train", "validation", "test", "holdout"]
CV_FOLDS_NAME = "cv-folds-v1.json"
LabelSubset = Literal["all", "iso_native", "legacy_apple", "xmp"]
TargetMode = Literal["per_image", "fixed_3stops", "iso_interval", "signed_stops"]
FIXED_GAIN_STOPS = 3.0

LEGACY_LABEL_CONTRACT_ID = "hyperdr.apple-gain-label/v1"

# v1 stored a non-negative float16 grid decoded with one legacy formula for
# every sample.  v2 stores signed float32 stops decoded with each sample's own
# ISO rationals.  They live under different names on purpose: a directory whose
# name says f16 must never come to hold signed float32 (H2).
V1_GAIN_GRID_DIRECTORY = "gain_grid_stride16_f16"
V2_GAIN_GRID_DIRECTORY = "gain_grid_stride16_f32_v2"
V2_INDEX_NAME = "training-cache-v2.jsonl"

V1_TARGET_MODES = ("per_image", "fixed_3stops")
V2_TARGET_MODES = ("fixed_3stops", "iso_interval", "signed_stops")
# signed_stops hands over raw signed stops with no normalization and no clip.
# It exists for A2's direct-regression control model, which must see exactly
# the quantity the interval model reconstructs -- otherwise the
# non-inferiority test would compare two different targets.
UNBOUNDED_TARGET_MODES = ("signed_stops",)

# The v2 grid is a convex average of values the decode formula already confines
# to [gain_min, gain_max], so M = (G - gain_min) / (gain_max - gain_min) lands
# in [0, 1] exactly.  This tolerance covers float32 rounding; a larger
# excursion is a broken label and is raised rather than clamped away.
INTERVAL_TOLERANCE = 1.0e-4

# Scalars that collate stacks alongside the tensors.  Every sample in a batch
# must agree on which of these it carries: a batch that silently mixed samples
# with and without a declared gain interval would average incomparable numbers.
# `stops_per_unit` and `stops_offset` are the inverse of whatever normalization
# the mode applied: absolute log2 gain = target * stops_per_unit + stops_offset.
# They are declared here, next to the forward map, so a consumer never has to
# re-derive it from the mode name -- under iso_interval the offset is the
# file's own gain_min, and under fixed_3stops it is zero.
OPTIONAL_SCALAR_KEYS = (
    "max_log2_gain",
    "saturated_pixel_fraction",
    "below_range_pixel_fraction",
    "gain_min",
    "gain_max",
    "stops_per_unit",
    "stops_offset",
)

# The H1 triple, kept as lists rather than stacked.  It rides the batch so a
# metric can be broken down by domain or traced to source bytes at the point it
# is computed, instead of being re-joined against a manifest afterwards by a
# consumer who may be holding a different manifest.
PROVENANCE_KEYS = (
    "domain",
    "writer_profile",
    "source_sha256",
)

# All three JSONL artifacts consumed by the dataset are emitted with
# ``sample_id`` as their first field.  Reading only that JSON string lets a
# fold decide whether a row belongs to it without deserializing (and therefore
# exposing or retaining) the rest of a held-out row's metadata.
_SAMPLE_ID_PREFIX = re.compile(
    rb'^\s*\{\s*"sample_id"\s*:\s*(?P<value>"(?:[^"\\]|\\.)*")'
)


def _finite_positive(value: object) -> bool:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return False
    return math.isfinite(number) and number > 0.0


def _read_jsonl_subset(
    path: Path,
    sample_ids: list[str] | tuple[str, ...],
    *,
    artifact: str,
) -> dict[str, dict[str, object]]:
    """Parse and retain only rows requested by an already-frozen split.

    Non-requested lines are inspected only far enough to extract their leading
    ``sample_id``.  In particular, malformed or sensitive metadata elsewhere
    on a held-out line is never passed to ``json.loads``.  Requested rows stay
    fail-closed: malformed JSON, an ID mismatch, duplicates, and missing rows
    all stop construction before training.
    """

    requested = {str(sample_id) for sample_id in sample_ids}
    rows: dict[str, dict[str, object]] = {}
    with path.open("rb") as handle:
        for number, line in enumerate(handle, start=1):
            if not line.strip():
                continue
            match = _SAMPLE_ID_PREFIX.match(line)
            if match is None:
                continue
            try:
                sample_id = str(json.loads(match.group("value")))
            except (json.JSONDecodeError, UnicodeDecodeError):
                # An unreadable ID cannot match a requested string.  If this
                # was meant to be a requested row, the missing-row check below
                # still fails closed without parsing any other field.
                continue
            if sample_id not in requested:
                continue
            try:
                row = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError) as exc:
                raise ValueError(
                    f"{path}:{number} is not valid JSON for requested "
                    f"{artifact} sample {sample_id!r}"
                ) from exc
            if not isinstance(row, dict):
                raise ValueError(
                    f"{path}:{number} is not an object for requested "
                    f"{artifact} sample {sample_id!r}"
                )
            parsed_id = str(row.get("sample_id", ""))
            if parsed_id != sample_id:
                raise ValueError(
                    f"{path}:{number} changes sample_id from {sample_id!r} "
                    f"to {parsed_id!r} while parsing"
                )
            if sample_id in rows:
                raise ValueError(
                    f"{path}:{number} repeats requested {artifact} sample_id "
                    f"{sample_id!r}"
                )
            rows[sample_id] = row

    missing = sorted(requested - rows.keys())
    if missing:
        raise ValueError(
            f"{len(missing)} of {len(requested)} requested sample(s) have no "
            f"{artifact} row in {path} (first: {missing[0]})"
        )
    return rows


class AppleGainMapDataset(Dataset):
    """Stride-16 gain targets paired with linear-P3 SDR proxies.

    The label contract is chosen by `allow_legacy_label_schema`, not inferred:
    the default is the v2 signed corpus, and reproducing the frozen v1
    normalized/float16 labels has to be asked for at the call site.
    """

    def __init__(
        self,
        root: str | Path,
        split: Split,
        label_subset: LabelSubset = "all",
        augment: bool = False,
        target_mode: TargetMode = "fixed_3stops",
        allow_legacy_label_schema: bool = False,
        fold: int | None = None,
        exclude_folds: tuple[int, ...] = (),
        one_shot_test_evaluation: bool = False,
        input_cache_dir: str | Path | None = None,
        target_cache_dir: str | Path | None = None,
    ) -> None:
        self.root = Path(root)
        self.label_contract_id = (
            LEGACY_LABEL_CONTRACT_ID if allow_legacy_label_schema else LABEL_CONTRACT_ID
        )
        self.uses_v2_labels = not allow_legacy_label_schema
        self.fold = fold
        self.exclude_folds = tuple(sorted(exclude_folds))
        self.input_cache_dir = (
            Path(input_cache_dir)
            if input_cache_dir is not None
            else self.root / "training" / "linear_p3_f16"
        )
        self.target_cache_dir = Path(target_cache_dir) if target_cache_dir is not None else None
        if (input_cache_dir is None) != (target_cache_dir is None):
            raise ValueError(
                "deployment input and target caches are a paired contract; "
                "both paths are required"
            )
        self.cv_freeze_id: str | None = None
        split_ids = self._split_members(
            split,
            fold,
            self.exclude_folds,
            one_shot_test_evaluation=one_shot_test_evaluation,
        )
        manifest = _read_jsonl_subset(
            self.root / "manifests" / "samples.jsonl",
            split_ids,
            artifact="sample manifest",
        )

        permitted = V2_TARGET_MODES if self.uses_v2_labels else V1_TARGET_MODES
        if target_mode not in permitted:
            raise ValueError(
                f"target_mode={target_mode!r} is not available under "
                f"{self.label_contract_id}; choose from {permitted}"
            )
        if label_subset not in {"all", "iso_native", "legacy_apple", "xmp"}:
            raise ValueError(f"unknown label_subset={label_subset!r}")

        self.labels: dict[str, dict[str, object]] = {}
        if self.uses_v2_labels:
            index_path = self.root / "manifests" / V2_INDEX_NAME
            if not index_path.exists():
                raise FileNotFoundError(
                    f"{index_path} is missing; build the v2 training grid with "
                    "scripts/build_gain_grid_v2.py, or pass "
                    "allow_legacy_label_schema=True to reproduce v1"
                )
            self.labels = _read_jsonl_subset(
                index_path,
                split_ids,
                artifact="v2 label index",
            )
            for row in self.labels.values():
                if row.get("label_contract_id") != LABEL_CONTRACT_ID:
                    raise ValueError(
                        f"{index_path} carries {row.get('label_contract_id')!r}; "
                        f"expected {LABEL_CONTRACT_ID}"
                    )

        if label_subset == "xmp":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if manifest[sample_id]["headroom_source"] == "xmp_hdr_gain_map_headroom"
            ]
        elif label_subset in ("iso_native", "legacy_apple"):
            wanted = "iso_21496_1_tmap" if label_subset == "iso_native" else "legacy_apple"
            legacy_version = 131072 if label_subset == "iso_native" else 65536
            split_ids = [
                sample_id
                for sample_id in split_ids
                if (
                    self.labels[sample_id]["source_type"] == wanted
                    if self.uses_v2_labels
                    else (
                        int(manifest[sample_id].get("gain_map_version") or 0) == legacy_version
                        or manifest[sample_id].get("phase_a_source_type") == wanted
                    )
                )
            ]
        if target_mode == "per_image":
            split_ids = [
                sample_id
                for sample_id in split_ids
                if _finite_positive(manifest[sample_id].get("canonical_max_log2_gain"))
            ]
        if self.uses_v2_labels:
            # Filtering can remove a source type from the yielded dataset.  Do
            # not keep those candidate label records alive on the Dataset
            # object after they have served that one membership decision.
            self.labels = {
                sample_id: self.labels[sample_id] for sample_id in split_ids
            }
        self.rows = [manifest[sample_id] for sample_id in split_ids]
        if self.target_cache_dir is not None:
            deployment_manifest = self.input_cache_dir / "deployment-cache.jsonl"
            if not deployment_manifest.is_file():
                raise FileNotFoundError(
                    f"paired deployment cache has no manifest: {deployment_manifest}"
                )
            deployment_rows = [
                json.loads(line)
                for line in deployment_manifest.read_text().splitlines()
                if line.strip()
            ]
            deployment_by_id = {
                str(record["sample_id"]): record for record in deployment_rows
            }
            if len(deployment_by_id) != len(deployment_rows):
                raise ValueError(f"duplicate sample ids in {deployment_manifest}")
            missing = sorted(set(split_ids) - deployment_by_id.keys())
            if missing:
                raise ValueError(
                    f"paired deployment manifest misses {len(missing)} selected "
                    f"sample(s), first {missing[0]}"
                )
            for sample_id in split_ids:
                target = deployment_by_id[sample_id].get("target")
                expected = (self.target_cache_dir / f"{sample_id}.npy").resolve()
                if not isinstance(target, dict) or target.get("contract") != (
                    "signed_log2_stops_rebased_to_deployment_sdr/v1"
                ):
                    raise ValueError(f"{sample_id}: deployment target contract is missing")
                if Path(str(target.get("file", ""))).resolve() != expected:
                    raise ValueError(f"{sample_id}: deployment target path disagrees with manifest")
                if not expected.is_file():
                    raise FileNotFoundError(expected)
        self.augment = augment
        self.target_mode = target_mode
        # Loaded after filtering, so the digest describes the samples this
        # dataset will actually yield rather than the split it started from.
        # It is loaded here and not lazily on first access: a missing or
        # incomplete ledger has to stop a run before it trains, not at whatever
        # point something first asks for provenance.
        self.provenance_ledger = ProvenanceLedger.load_subset(self.root, split_ids)
        self.provenance = {
            str(record["sample_id"]): record
            for record in self.provenance_ledger.require(split_ids)
        }
        self.provenance_digest = self.provenance_ledger.digest(
            split_ids, run_label_contract_id=self.label_contract_id
        )

    def _read_fold_record(self) -> dict[str, object]:
        folds_path = self.root / "splits" / CV_FOLDS_NAME
        if not folds_path.exists():
            raise FileNotFoundError(
                f"{folds_path} is missing; freeze the fold partition with "
                "scripts/build_cv_folds.py"
            )
        record = json.loads(folds_path.read_text())
        self.cv_freeze_id = str(record["freeze_id"])
        return record

    def _split_members(
        self,
        split: Split,
        fold: int | None,
        exclude_folds: tuple[int, ...],
        *,
        one_shot_test_evaluation: bool,
    ) -> list[str]:
        """Sample ids for a named split, or for one side of a CV fold.

        The two fold arguments are deliberately not interchangeable, because
        conflating them is how a judgment fold ends up being looked at:

          `fold`           the single fold a `holdout` split *is*.
          `exclude_folds`  the folds a `train` split leaves out -- normally both
                           the judgment fold and the selection fold, so that
                           training never touches either.

        `test` ignores both fold arguments, but it is not readable by default.
        The evaluator must pass `one_shot_test_evaluation=True` after enforcing
        its one-shot policy.  This capability prevents an incidental dataset
        construction from exposing test membership; durable accounting of the
        single use belongs to the command that owns the evaluation record (H3).
        """
        splits_dir = self.root / "splits"
        if split == "test":
            if not one_shot_test_evaluation:
                raise ValueError(
                    "split='test' is fail-closed; the frozen test split may only "
                    "be opened by the one-shot evaluator, which must pass "
                    "one_shot_test_evaluation=True after recording that access (H3)"
                )
            return json.loads((splits_dir / "test.json").read_text())["sample_ids"]
        if one_shot_test_evaluation:
            raise ValueError(
                "one_shot_test_evaluation applies only to split='test'; refusing "
                f"to misfile test authorization as split={split!r}"
            )
        if split == "holdout":
            if fold is None:
                raise ValueError("split='holdout' requires a fold index")
            if exclude_folds:
                raise ValueError("split='holdout' is a single fold; exclude_folds is meaningless")
            record = self._read_fold_record()
            self._check_range(fold, record)
            return sorted(s for s, i in record["sample_fold"].items() if i == fold)
        if split == "train" and exclude_folds:
            if fold is not None:
                raise ValueError(
                    "pass exclude_folds for a 'train' split, not fold; naming which "
                    "fold a training set is 'for' is what lets it quietly include it"
                )
            record = self._read_fold_record()
            for index in exclude_folds:
                self._check_range(index, record)
            removed = set(exclude_folds)
            return sorted(
                s for s, i in record["sample_fold"].items() if i not in removed
            )
        if fold is not None:
            raise ValueError(
                f"split={split!r} takes no fold index; use 'holdout' with fold, or "
                "'train' with exclude_folds"
            )
        return json.loads((splits_dir / f"{split}.json").read_text())["sample_ids"]

    @staticmethod
    def _check_range(fold: int, record: dict[str, object]) -> None:
        if not 0 <= fold < int(record["fold_count"]):
            raise ValueError(
                f"fold {fold} is out of range for a {record['fold_count']}-fold partition"
            )

    def __len__(self) -> int:
        return len(self.rows)

    def _load_gain_grid(self, sample_id: str) -> np.ndarray:
        if self.target_cache_dir is not None:
            if not self.uses_v2_labels:
                raise ValueError("a deployment target cache requires the v2 signed label contract")
            path = self.target_cache_dir / f"{sample_id}.npy"
        else:
            directory = (
                V2_GAIN_GRID_DIRECTORY if self.uses_v2_labels else V1_GAIN_GRID_DIRECTORY
            )
            path = self.root / "training" / directory / f"{sample_id}.npy"
        grid = np.load(
            path, allow_pickle=False
        ).astype(np.float32)
        if not np.isfinite(grid).all():
            raise ValueError(f"Non-finite gain grid for sample {sample_id}")
        return grid

    def normalized_target(
        self, row: dict[str, object]
    ) -> tuple[np.ndarray, dict[str, float], dict[str, int]]:
        """Normalize one sample's gain grid, plus the scalars that describe it.

        Returns the clipped target, the per-sample scalars that travel with it
        in a batch, and integer diagnostics counted *before* clipping.
        `__getitem__` and `target_statistics` both go through here so the audit
        can never describe a different target than the one training sees.
        """
        sample_id = str(row["sample_id"])
        gain = self._load_gain_grid(sample_id)

        if self.uses_v2_labels:
            label = self.labels[sample_id]
            gain_min = float(label["gain_min"])
            gain_max = float(label["gain_max"])
            if not (math.isfinite(gain_min) and math.isfinite(gain_max)):
                raise ValueError(f"Non-finite gain interval for {sample_id}")
            if gain_max - gain_min <= 0.0:
                raise ValueError(f"Degenerate gain interval for {sample_id}")
            if self.target_mode == "iso_interval":
                width = gain_max - gain_min
                normalized = (gain - gain_min) / width
                low, high = float(normalized.min()), float(normalized.max())
                if low < -INTERVAL_TOLERANCE or high > 1.0 + INTERVAL_TOLERANCE:
                    raise ValueError(
                        f"{sample_id}: normalized target range [{low}, {high}] escapes "
                        f"the declared interval [{gain_min}, {gain_max}]"
                    )
                scalars = {
                    "max_log2_gain": gain_max,
                    "gain_min": gain_min,
                    "gain_max": gain_max,
                    "stops_per_unit": width,
                    "stops_offset": gain_min,
                }
            elif self.target_mode == "signed_stops":
                normalized = gain  # already signed stops; identity map back
                scalars = {
                    "max_log2_gain": gain_max,
                    "gain_min": gain_min,
                    "gain_max": gain_max,
                    "stops_per_unit": 1.0,
                    "stops_offset": 0.0,
                }
            else:  # fixed_3stops on v2: same parameterization as v1, correct decode
                normalized = gain / FIXED_GAIN_STOPS
                scalars = {
                    "max_log2_gain": gain_max,
                    "gain_min": gain_min,
                    "gain_max": gain_max,
                    "stops_per_unit": FIXED_GAIN_STOPS,
                    "stops_offset": 0.0,
                }
        else:
            max_log2_gain = float(row["canonical_max_log2_gain"])
            if not math.isfinite(max_log2_gain) or max_log2_gain < 0.0:
                raise ValueError(f"Invalid max_log2_gain={max_log2_gain!r} for {sample_id}")
            if self.target_mode == "per_image" and max_log2_gain <= 0.0:
                raise ValueError(
                    f"per_image target requires finite max_log2_gain > 0 for {sample_id}"
                )
            scale = max_log2_gain if self.target_mode == "per_image" else FIXED_GAIN_STOPS
            normalized = gain / scale
            scalars = {
                "max_log2_gain": max_log2_gain,
                "gain_min": 0.0,
                "gain_max": max_log2_gain,
                "stops_per_unit": scale,
                "stops_offset": 0.0,
            }

        if not np.isfinite(normalized).all():
            raise ValueError(f"Non-finite normalized target for sample {sample_id}")
        # Count only pixels the clip actually moves, not float32 ties at the
        # endpoints.  Under iso_interval the brightest pixel of a file sits
        # exactly on gain_max, so an exact `> 1.0` test reports a saturation
        # rate of ~5e-4 that is entirely rounding and would read as a real
        # property of the corpus.  A pixel within INTERVAL_TOLERANCE of an
        # endpoint is at most ~1e-4 * width stops away from it.
        diagnostics = {
            "pixels": int(normalized.size),
            "saturated_pixels": int((normalized > 1.0 + INTERVAL_TOLERANCE).sum()),
            "below_range_pixels": int((normalized < -INTERVAL_TOLERANCE).sum()),
        }
        scalars["saturated_pixel_fraction"] = diagnostics["saturated_pixels"] / normalized.size
        scalars["below_range_pixel_fraction"] = diagnostics["below_range_pixels"] / normalized.size
        if self.target_mode in UNBOUNDED_TARGET_MODES:
            # Clipping here would hand the control model a truncated target and
            # then measure it against the interval model on the untruncated one.
            return normalized, scalars, diagnostics
        return np.clip(normalized, 0.0, 1.0), scalars, diagnostics

    def __getitem__(self, index: int) -> dict[str, torch.Tensor | str]:
        row = self.rows[index]
        sample_id = str(row["sample_id"])
        sdr = torch.from_numpy(
            np.load(self.input_cache_dir / f"{sample_id}.npy", allow_pickle=False)
            .astype(np.float32)
        )
        normalized, scalars, _ = self.normalized_target(row)
        target = torch.from_numpy(normalized)
        _validate_spatial_sample(sample_id, sdr, target)
        if not torch.isfinite(sdr).all():
            raise ValueError(f"Non-finite cached tensor for sample {sample_id}")
        if self.augment and bool(torch.rand(()) < 0.5):
            sdr = torch.flip(sdr, dims=(-1,))
            target = torch.flip(target, dims=(-1,))
        record = self.provenance[sample_id]
        sample: dict[str, torch.Tensor | str] = {
            "sample_id": sample_id,
            "domain": str(record["domain"]),
            "writer_profile": str(record["writer_profile"]),
            "source_sha256": str(record["source_sha256"]),
            "sdr": sdr,
            "target": target,
        }
        for name, value in scalars.items():
            sample[name] = torch.tensor(float(value), dtype=torch.float32)
        return sample


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
    batch: dict[str, torch.Tensor | list[str]] = {
        "sample_id": [str(sample["sample_id"]) for sample in samples],
        "sdr": torch.stack(batch_sdr),
        "target": torch.stack(batch_target),
        "mask": torch.stack(batch_mask),
    }
    for name in PROVENANCE_KEYS:
        present = [name in sample for sample in samples]
        if all(present):
            batch[name] = [str(sample[name]) for sample in samples]
        elif any(present):
            # Same rule as the scalars below, and it matters more here: a batch
            # where only some samples carry provenance would let an H1 breakdown
            # silently describe a subset of the rows it claims to cover.
            raise ValueError(
                f"{name!r} is present on only {sum(present)}/{len(samples)} samples; "
                "a batch cannot mix samples that declare it with samples that do not"
            )
    for name in OPTIONAL_SCALAR_KEYS:
        present = [name in sample for sample in samples]
        if all(present):
            batch[name] = torch.stack([sample[name] for sample in samples])
        elif any(present):
            raise ValueError(
                f"{name!r} is present on only {sum(present)}/{len(samples)} samples; "
                "a batch cannot mix samples that declare it with samples that do not"
            )
    return batch


class ShapeBucketBatchSampler(Sampler):
    """Batch only samples of identical shape, so no padding is ever needed.

    collate pads a batch up to its largest member, and every GroupNorm in the
    trunk computes its statistics over the padded extent -- so padding does not
    stay in the padded corner, it shifts *every* activation in the sample.
    Measured on one ConvBlock, appending 50% zero padding moves activations far
    from the boundary by ~2.3; with the norms bypassed the same drift is 3e-08
    (and 4e-02 in the boundary column, which is the genuine receptive-field
    effect).  So without bucketing, a sample's prediction depends on which other
    samples happened to share its batch.

    That matters everywhere, and it is disqualifying for a per-file scalar like
    the gain interval.  This corpus has exactly two proxy shapes (768x1024 and
    1024x768, 437/410), so two random samples differ in shape half the time and
    a mixed batch pads to 1024x1024 -- 25% zeros.  Bucketing removes the padding
    outright instead of compensating for it.
    """

    def __init__(
        self,
        shapes: list[tuple[int, int]],
        batch_size: int,
        shuffle: bool,
        generator: torch.Generator | None = None,
    ) -> None:
        if batch_size <= 0:
            raise ValueError(f"batch_size must be positive, got {batch_size}")
        self.batch_size = batch_size
        self.shuffle = shuffle
        self.generator = generator
        self.buckets: dict[tuple[int, int], list[int]] = {}
        for index, shape in enumerate(shapes):
            self.buckets.setdefault(tuple(shape), []).append(index)
        self.batch_count = sum(
            (len(indices) + batch_size - 1) // batch_size
            for indices in self.buckets.values()
        )

    def __len__(self) -> int:
        return self.batch_count

    def __iter__(self):
        batches: list[list[int]] = []
        for _, indices in sorted(self.buckets.items()):
            order = list(indices)
            if self.shuffle:
                permutation = torch.randperm(len(order), generator=self.generator)
                order = [order[position] for position in permutation.tolist()]
            batches.extend(
                order[start : start + self.batch_size]
                for start in range(0, len(order), self.batch_size)
            )
        if self.shuffle:
            permutation = torch.randperm(len(batches), generator=self.generator)
            batches = [batches[position] for position in permutation.tolist()]
        return iter(batches)


def grid_shapes(dataset: AppleGainMapDataset) -> list[tuple[int, int]]:
    """Each sample's stride-16 target grid, for bucketing without loading it."""
    return [
        target_grid_size(tuple(int(value) for value in row["proxy_size"]))
        for row in dataset.rows
    ]


def target_statistics(dataset: AppleGainMapDataset) -> dict[str, float | int | str]:
    """Scan the normalized targets without loading any SDR tensor."""
    target_sum = 0.0
    pixel_count = 0
    saturated_pixels = 0
    saturated_samples = 0
    below_range_pixels = 0
    below_range_samples = 0
    declared_max_above_fixed_scale = 0
    negative_gain_min_samples = 0
    gain_min_sum = 0.0
    gain_range_sum = 0.0
    for row in dataset.rows:
        normalized, scalars, diagnostics = dataset.normalized_target(row)
        declared_max_above_fixed_scale += int(
            scalars["max_log2_gain"] > FIXED_GAIN_STOPS
        )
        negative_gain_min_samples += int(scalars["gain_min"] < 0.0)
        gain_min_sum += scalars["gain_min"]
        gain_range_sum += scalars["gain_max"] - scalars["gain_min"]
        saturated_pixels += diagnostics["saturated_pixels"]
        saturated_samples += int(diagnostics["saturated_pixels"] > 0)
        below_range_pixels += diagnostics["below_range_pixels"]
        below_range_samples += int(diagnostics["below_range_pixels"] > 0)
        target_sum += float(normalized.sum(dtype=np.float64))
        pixel_count += diagnostics["pixels"]
    return {
        "label_contract_id": dataset.label_contract_id,
        "target_mode": dataset.target_mode,
        "samples": len(dataset),
        "pixels": pixel_count,
        "masked_target_mean": target_sum / pixel_count if pixel_count else 0.0,
        "saturated_samples": saturated_samples,
        "saturated_sample_fraction": (
            saturated_samples / len(dataset) if len(dataset) else 0.0
        ),
        "below_range_samples": below_range_samples,
        "below_range_sample_fraction": (
            below_range_samples / len(dataset) if len(dataset) else 0.0
        ),
        "declared_max_above_3_stops_samples": declared_max_above_fixed_scale,
        "declared_max_above_3_stops_sample_fraction": (
            declared_max_above_fixed_scale / len(dataset)
            if len(dataset)
            else 0.0
        ),
        "negative_gain_min_samples": negative_gain_min_samples,
        # Endpoint means, for initializing the metadata head at the corpus
        # centre rather than at zero.
        "mean_gain_min": gain_min_sum / len(dataset) if len(dataset) else 0.0,
        "mean_gain_range": gain_range_sum / len(dataset) if len(dataset) else 0.0,
        "saturated_pixels": saturated_pixels,
        "saturated_pixel_fraction": (
            saturated_pixels / pixel_count if pixel_count else 0.0
        ),
        "below_range_pixels": below_range_pixels,
        "below_range_pixel_fraction": (
            below_range_pixels / pixel_count if pixel_count else 0.0
        ),
    }
