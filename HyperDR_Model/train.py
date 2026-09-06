#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import nullcontext
import hashlib
import json
import math
import os
import random
import time
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import torch
from torch.optim import AdamW
from torch.utils.data import DataLoader

from hyperdr_ml.data import (
    CV_FOLDS_NAME,
    AppleGainMapDataset,
    ShapeBucketBatchSampler,
    TargetMode,
    collate_gain_maps,
    grid_shapes,
    target_statistics,
)
from hyperdr_ml.loss import (
    DEFAULT_GLOBAL_MEAN_WEIGHT,
    DEFAULT_GRADIENT_WEIGHT,
    IntervalLossWeights,
    direct_gain_loss,
    gain_loss,
    interval_gain_loss,
)
from hyperdr_ml.model import (
    Architecture,
    DirectGainNet,
    GainMapNet,
    IntervalGainMapNet,
)
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file
from hyperdr_ml.provenance import compare_digests

# Which target parameterization each model can consume.  A2's comparison is
# only meaningful if each model sees the target its head is built for, so the
# pairing is enforced rather than left to the caller.
MODEL_TARGET_MODES = {
    "map_only": ("per_image", "fixed_3stops", "iso_interval"),
    "interval": ("iso_interval",),
    "direct": ("signed_stops",),
}


@dataclass
class Config:
    dataset_root: str
    output_dir: str
    model_id: str
    input_cache_dir: str | None
    target_cache_dir: str | None
    label_subset: str
    target_mode: TargetMode
    model: str
    architecture: Architecture
    lambda_gain_min: float
    lambda_gain_max: float
    lambda_reconstructed_gain: float
    lambda_gradient: float
    lambda_global_mean: float
    epochs: int
    batch_size: int
    learning_rate: float
    weight_decay: float
    base_channels: int
    num_workers: int
    seed: int
    compile_model: bool
    highlight_weight: float
    initialize_output_bias: bool
    resume: str | None
    initialize_from_checkpoint: str | None
    fold: int | None
    selection_fold: int | None
    production_selection_fold: int | None
    batch_by_shape: bool
    allow_legacy_label_schema: bool


# Paths describe where artifacts happen to live, not the numerical experiment.
# Everything else in Config can affect model state, sample order, or targets and
# is therefore part of the hash that a resumable checkpoint must match.
CONFIG_HASH_EXCLUDED_FIELDS = frozenset(
    ("output_dir", "resume", "initialize_from_checkpoint", "model_id")
)


def _canonical_sha256(value: object) -> str:
    payload = json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def reproducibility_config(config: Config | dict[str, Any]) -> dict[str, Any]:
    """Configuration fields that define the numerical training run."""
    values = asdict(config) if isinstance(config, Config) else dict(config)
    result = {
        name: value
        for name, value in values.items()
        if name not in CONFIG_HASH_EXCLUDED_FIELDS
    }
    # Preserve the exact production-v3 hash: the original run predates this
    # optional field, and None selects the same legacy cache it used.
    if result.get("input_cache_dir") is None:
        result.pop("input_cache_dir", None)
    if result.get("target_cache_dir") is None:
        result.pop("target_cache_dir", None)
    return result


def config_sha256(config: Config | dict[str, Any]) -> str:
    """Stable hash of every result-affecting configuration field."""
    return _canonical_sha256(reproducibility_config(config))


def registered_test_split_sha256(config: Config) -> str:
    """Frozen test hash from the CV registry, without opening test.json."""
    path = Path(config.dataset_root) / "splits" / CV_FOLDS_NAME
    record = json.loads(path.read_text(encoding="utf-8"))
    sources = record.get("source_sha256")
    if not isinstance(sources, dict):
        raise ValueError(f"{path} has no source_sha256 registry")
    value = str(sources.get("test.json", "")).lower()
    if len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise ValueError(f"{path} has no valid registered test.json SHA-256")
    return value


def split_file_hashes(config: Config) -> dict[str, str]:
    """Hashes of every split artifact that defines or audits this run.

    Development must not even open the frozen one-shot test file.  Its hash is
    therefore copied from the source registry already frozen in
    cv-folds-v1.json; the real test bytes are verified only after a global
    one-shot claim. Fold runs additionally pin the exact CV assignment from
    which train/selection/judgment membership is derived.
    """
    names = {"train.json", "validation.json", "groups.json"}
    if config.fold is not None or config.production_selection_fold is not None:
        names.add(CV_FOLDS_NAME)
    directory = Path(config.dataset_root) / "splits"
    result = {name: sha256_file(directory / name) for name in sorted(names)}
    # Keep the checkpoint key compatible with consumers, but its value is the
    # registered hash, not a development-time read of test.json.
    result["test.json"] = registered_test_split_sha256(config)
    return dict(sorted(result.items()))


def checkpoint_identity(config: Config) -> dict[str, object]:
    """Immutable experiment identity captured before any dataset is loaded."""
    identity: dict[str, object] = {
        "config_sha256": config_sha256(config),
        "manifest_sha256": sha256_file(
            Path(config.dataset_root) / "manifests" / "samples.jsonl"
        ),
        "split_sha256": split_file_hashes(config),
    }
    if config.input_cache_dir is not None:
        cache_manifest = Path(config.input_cache_dir) / "deployment-cache.jsonl"
        if not cache_manifest.is_file():
            raise FileNotFoundError(
                f"deployment input cache has no manifest: {cache_manifest}"
            )
        identity["deployment_cache_manifest_sha256"] = sha256_file(cache_manifest)
        identity["deployment_target_contract"] = (
            "signed_log2_stops_rebased_to_deployment_sdr/v1"
        )
    return identity


def parse_args() -> Config:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dataset-root", default=str(Path.home() / "datasets/hyperdr-apple")
    )
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--model-id",
        default="hyperdr.direct-experiment/unversioned",
        help="stable artifact identity recorded in config/checkpoints; not a score",
    )
    parser.add_argument(
        "--input-cache-dir",
        help=(
            "optional CHW .npy cache replacing training/linear_p3_f16; use a "
            "deployment-matched cache built by scripts/build_deployment_cache.py"
        ),
    )
    parser.add_argument(
        "--target-cache-dir",
        help=(
            "paired signed-stop .npy targets rebased to --input-cache-dir; "
            "deployment training requires both cache arguments"
        ),
    )
    parser.add_argument(
        "--label-subset",
        choices=("iso_native", "legacy_apple", "all", "xmp"),
        default="iso_native",
    )
    parser.add_argument(
        "--target-mode",
        choices=("per_image", "fixed_3stops", "iso_interval", "signed_stops"),
        default="fixed_3stops",
        help=(
            "iso_interval targets M = (G - gain_min) / (gain_max - gain_min) from the "
            "v2 labels; signed_stops targets raw signed G; per_image is only "
            "available under --allow-legacy-label-schema"
        ),
    )
    parser.add_argument(
        "--model",
        choices=tuple(MODEL_TARGET_MODES),
        default="map_only",
        help=(
            "map_only predicts the spatial map and takes the interval from the label; "
            "interval adds A2's metadata head; direct is A2's control model, "
            "regressing signed G with a linear head"
        ),
    )
    # Defaults are None so that setting a weight the chosen model ignores can be
    # rejected instead of silently recorded in config.json as though it applied.
    # The map term is pinned at 1 and has no flag: scaling all terms together is
    # degenerate with the learning rate.
    for name in (
        "--lambda-gain-min",
        "--lambda-gain-max",
        "--lambda-reconstructed-gain",
        "--lambda-gradient",
        "--lambda-global-mean",
    ):
        parser.add_argument(name, type=float, default=None)
    parser.add_argument(
        "--architecture",
        choices=("baseline", "global_conditioning", "dilation_pyramid"),
        default="baseline",
    )
    parser.add_argument("--epochs", type=int, default=60)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--base-channels", type=int, default=24)
    parser.add_argument("--num-workers", type=int, default=4)
    parser.add_argument("--seed", type=int, default=20260730)
    parser.add_argument("--compile-model", action="store_true")
    parser.add_argument("--highlight-weight", type=float, default=0.0)
    parser.add_argument(
        "--no-target-mean-init",
        action="store_false",
        dest="initialize_output_bias",
    )
    parser.add_argument("--resume", type=str)
    parser.add_argument(
        "--initialize-from-checkpoint",
        type=str,
        help=(
            "load model weights only, then start at epoch 1 with a fresh optimizer, "
            "scheduler, RNG stream, and run config; mutually exclusive with --resume"
        ),
    )
    parser.add_argument(
        "--fold",
        type=int,
        help=(
            "the judgment fold, per splits/cv-folds-v1.json. It is excluded from "
            "training and NEVER loaded during the run: score it afterwards with "
            "evaluate_absolute.py. Requires --selection-fold. Pooling every fold's "
            "out-of-fold predictions gives the bootstrap 261 capture groups on the "
            "iso_native subset (477 on the whole pool) against the 31 a single "
            "validation split has. test is never part of any fold (H3)"
        ),
    )
    parser.add_argument(
        "--selection-fold",
        type=int,
        help=(
            "the only fold anything may be selected on -- epoch, checkpoint, and "
            "any hyperparameter search. Excluded from training too, and must "
            "differ from --fold, so no signal computed on the judgment fold can "
            "reach a choice"
        ),
    )
    parser.add_argument(
        "--production-selection-fold",
        type=int,
        help=(
            "fit one deployable model on every registered development fold except "
            "this checkpoint-selection fold. Unlike --fold/--selection-fold, no "
            "outer judgment fold is withheld or scored by this run"
        ),
    )
    parser.add_argument(
        "--no-batch-by-shape",
        action="store_false",
        dest="batch_by_shape",
        help=(
            "reproduce the pre-2026-08-07 mixed-shape batching, in which "
            "GroupNorm statistics were computed over collate's zero padding and "
            "a sample's prediction depended on its batch mates"
        ),
    )
    parser.add_argument(
        "--allow-legacy-label-schema",
        action="store_true",
        help="explicitly reproduce the frozen v1 normalized/f16 labels",
    )
    parser.set_defaults(initialize_output_bias=True, batch_by_shape=True)
    values = parser.parse_args()
    if values.epochs <= 0 or values.batch_size <= 0:
        parser.error("--epochs and --batch-size must be positive")
    if values.base_channels <= 0 or values.num_workers < 0:
        parser.error("--base-channels must be positive and --num-workers non-negative")
    if not values.model_id.strip():
        parser.error("--model-id must not be empty")
    if values.input_cache_dir is not None:
        values.input_cache_dir = str(Path(values.input_cache_dir).resolve())
    if values.target_cache_dir is not None:
        values.target_cache_dir = str(Path(values.target_cache_dir).resolve())
    if (values.input_cache_dir is None) != (values.target_cache_dir is None):
        parser.error(
            "--input-cache-dir and --target-cache-dir are a paired deployment "
            "contract and must be supplied together"
        )
    permitted = MODEL_TARGET_MODES[values.model]
    if values.target_mode not in permitted:
        parser.error(
            f"--model {values.model} requires --target-mode from {permitted}, "
            f"got {values.target_mode}"
        )
    if values.model != "map_only" and values.allow_legacy_label_schema:
        parser.error(
            f"--model {values.model} needs the v2 signed labels; "
            "it has no meaning under the v1 schema"
        )

    # A weight the model's loss never reads would still be written to
    # config.json and compared on resume, which reads as though it had been
    # tuned. Reject it instead.
    ignored = {
        "map_only": ("lambda_gain_min", "lambda_gain_max", "lambda_reconstructed_gain"),
        "direct": ("lambda_gain_min", "lambda_gain_max", "lambda_reconstructed_gain"),
        "interval": (),
    }[values.model]
    for name in ignored:
        if getattr(values, name) is not None:
            parser.error(
                f"--{name.replace('_', '-')} has no effect on --model {values.model}; "
                "its loss does not read it"
            )
    for name, default in (
        ("lambda_gain_min", 1.0),
        ("lambda_gain_max", 1.0),
        ("lambda_reconstructed_gain", 1.0),
        ("lambda_gradient", DEFAULT_GRADIENT_WEIGHT),
        ("lambda_global_mean", DEFAULT_GLOBAL_MEAN_WEIGHT),
    ):
        if getattr(values, name) is None:
            setattr(values, name, default)

    if (values.fold is None) != (values.selection_fold is None):
        parser.error("--fold and --selection-fold must be given together")
    if values.fold is not None and values.fold == values.selection_fold:
        parser.error(
            "--selection-fold must differ from --fold; selecting on the judgment "
            "fold is exactly the contamination the split exists to prevent"
        )
    if values.production_selection_fold is not None and (
        values.fold is not None or values.selection_fold is not None
    ):
        parser.error(
            "--production-selection-fold is mutually exclusive with "
            "--fold/--selection-fold"
        )
    if values.production_selection_fold is not None and values.production_selection_fold < 0:
        parser.error("--production-selection-fold must be non-negative")
    if values.resume and values.initialize_from_checkpoint:
        parser.error("--resume and --initialize-from-checkpoint are mutually exclusive")
    return Config(**vars(values))


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def configure_deterministic_execution() -> None:
    """Make a seeded run reproducible across restart on the same stack.

    PyTorch does not promise bitwise identity across releases or devices, but
    within one runtime we fail rather than silently select a nondeterministic
    CUDA kernel.  cuBLAS needs its workspace policy before the first CUDA
    context is created.
    """
    workspace = os.environ.get("CUBLAS_WORKSPACE_CONFIG")
    permitted = {":4096:8", ":16:8"}
    if workspace is None:
        os.environ["CUBLAS_WORKSPACE_CONFIG"] = ":4096:8"
    elif workspace not in permitted:
        raise RuntimeError(
            "CUBLAS_WORKSPACE_CONFIG must be ':4096:8' or ':16:8' for a "
            f"deterministic run, got {workspace!r}"
        )
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    torch.backends.cuda.matmul.allow_tf32 = False
    torch.backends.cudnn.allow_tf32 = False
    torch.use_deterministic_algorithms(True)


def make_loader(config: Config, split: str, augment: bool) -> DataLoader:
    # In fold mode the training set drops BOTH the judgment fold and the
    # selection fold, and the scored split is the selection fold. The judgment
    # fold is not loaded anywhere in this process.
    holdout_fold = (
        config.production_selection_fold
        if config.production_selection_fold is not None
        else config.selection_fold
    )
    fold = holdout_fold if split == "holdout" else None
    if split == "train" and config.production_selection_fold is not None:
        exclude = (config.production_selection_fold,)
    elif split == "train" and config.fold is not None:
        exclude = (config.fold, config.selection_fold)
    else:
        exclude = ()
    dataset = AppleGainMapDataset(
        config.dataset_root,
        split,
        config.label_subset,
        augment,
        config.target_mode,
        allow_legacy_label_schema=config.allow_legacy_label_schema,
        fold=fold,
        exclude_folds=exclude,
        input_cache_dir=config.input_cache_dir,
        target_cache_dir=config.target_cache_dir,
    )
    generator = torch.Generator().manual_seed(
        config.seed + (0 if split == "train" else 1)
    )
    shared = dict(
        num_workers=config.num_workers,
        pin_memory=True,
        # Worker-local RNG state cannot be serialized from persistent worker
        # processes. Recreate workers at each epoch so their seeds come from
        # the DataLoader generator, whose state is in every checkpoint.
        persistent_workers=False,
        collate_fn=collate_gain_maps,
        generator=generator,
    )
    if config.batch_by_shape:
        return DataLoader(
            dataset,
            batch_sampler=ShapeBucketBatchSampler(
                grid_shapes(dataset),
                config.batch_size,
                shuffle=split == "train",
                generator=generator,
            ),
            **shared,
        )
    return DataLoader(
        dataset,
        batch_size=config.batch_size,
        shuffle=split == "train",
        **shared,
    )


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast(device_type="cuda", dtype=torch.bfloat16)
    return nullcontext()


def highlight_metric_name(target_mode: TargetMode) -> str:
    return (
        "relative_high_gain_mae"
        if target_mode == "per_image"
        else "absolute_highlight_mae_stops"
    )


# Capture-group weighted, because the A2 judgment weights groups equally and a
# selection metric must be the same functional as the judgment metric.  Weighting
# by image instead would let a four-image capture group outvote three singletons
# when choosing an epoch or a configuration, and then judge on a statistic that
# does not.
CAPTURE_GROUP_SUFFIX = "_by_capture_group"


def primary_metric_name(model_kind: str) -> str:
    """What "best" means for each model.

    `map_only` is scored on the normalized map it predicts.  The other two are
    scored on absolute log2-gain MAE in stops, weighted by capture group -- the
    verdict's primary metric, identical in definition between them, which is
    what lets the non-inferiority test compare them at all.
    """
    return "mae" if model_kind == "map_only" else f"g_mae_stops{CAPTURE_GROUP_SUFFIX}"


def capture_group_map(dataset_root: str | Path) -> dict[str, str]:
    groups = json.loads(
        (Path(dataset_root) / "splits" / "groups.json").read_text()
    )["groups"]
    return {
        sample_id: str(group["group_id"])
        for group in groups
        for sample_id in group["members"]
    }


def secondary_metric_name(model_kind: str, target_mode: TargetMode) -> str:
    return (
        highlight_metric_name(target_mode)
        if model_kind == "map_only"
        else "absolute_highlight_mae_stops"
    )


def build_model(config: Config) -> torch.nn.Module:
    if config.model == "interval":
        return IntervalGainMapNet(config.base_channels, config.architecture)
    if config.model == "direct":
        return DirectGainNet(config.base_channels, config.architecture)
    return GainMapNet(config.base_channels, config.architecture)


def compute_loss(
    model: torch.nn.Module,
    config: Config,
    batch: dict[str, torch.Tensor],
    device: torch.device,
    loss_weights: IntervalLossWeights,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    sdr = batch["sdr"].to(device, non_blocking=True)
    target = batch["target"].to(device, non_blocking=True)
    mask = batch["mask"].to(device, non_blocking=True)
    if config.model == "interval":
        prediction = model(sdr, mask)
        return interval_gain_loss(
            {name: value.float() for name, value in prediction.items()},
            target,
            mask,
            batch["gain_min"].to(device, non_blocking=True),
            batch["gain_max"].to(device, non_blocking=True),
            config.highlight_weight,
            loss_weights,
        )
    if config.model == "direct":
        return direct_gain_loss(
            model(sdr).float(),
            target,
            mask,
            config.highlight_weight,
            config.lambda_gradient,
            config.lambda_global_mean,
        )
    # per_image normalizes by a per-image quantity with no absolute meaning,
    # so it deliberately has no stops scale to hand to the loss.
    stops_per_unit = (
        None
        if config.target_mode == "per_image"
        else batch["stops_per_unit"].to(device, non_blocking=True)
    )
    return gain_loss(
        model(sdr).float(),
        target,
        mask,
        config.highlight_weight,
        config.target_mode,
        stops_per_unit,
        config.lambda_gradient,
        config.lambda_global_mean,
    )


def run_epoch(
    model: torch.nn.Module,
    loader: DataLoader,
    optimizer: AdamW | None,
    device: torch.device,
    config: Config,
    group_of: dict[str, str] | None = None,
) -> dict[str, float]:
    training = optimizer is not None
    model.train(training)
    totals = defaultdict(float)
    weights = defaultdict(float)
    per_image: dict[str, list[tuple[str, float]]] = defaultdict(list)
    sample_count = 0
    start = time.perf_counter()
    loss_weights = IntervalLossWeights(
        gain_min=config.lambda_gain_min,
        gain_max=config.lambda_gain_max,
        reconstructed_gain=config.lambda_reconstructed_gain,
        gradient=config.lambda_gradient,
        global_mean=config.lambda_global_mean,
    )
    for batch in loader:
        if optimizer is not None:
            optimizer.zero_grad(set_to_none=True)
        with torch.set_grad_enabled(training), autocast_context(device):
            loss, metrics = compute_loss(model, config, batch, device, loss_weights)
        if not torch.isfinite(loss):
            raise FloatingPointError("Non-finite loss; refusing to update model")
        if optimizer is not None:
            loss.backward()
            gradient_norm = torch.nn.utils.clip_grad_norm_(
                model.parameters(), max_norm=1.0
            )
            if not torch.isfinite(gradient_norm):
                raise FloatingPointError(
                    "Non-finite gradient norm; refusing to update model"
                )
            optimizer.step()
        count = int(batch["sdr"].shape[0])
        sample_count += count
        # Metrics defined on a subset of images declare their own weight next to
        # themselves; everything else is per-image over the whole batch.
        metric_weights = {
            name: float(value)
            for name, value in metrics.get("_metric_weights", {}).items()
        }
        for name, values in metrics.get("_per_image", {}).items():
            per_image[name].extend(zip(batch["sample_id"], values.tolist()))
        for name, value in metrics.items():
            if name.startswith("_"):
                continue
            weight = metric_weights.get(name, count)
            if weight:
                totals[name] += float(value) * weight
                weights[name] += weight
    elapsed = time.perf_counter() - start
    result = {
        name: totals[name] / weights[name] for name in sorted(totals)
    }
    if group_of is not None:
        # Average within capture group, then weight groups equally -- the same
        # functional the judgment uses, so selection optimizes what is judged.
        for name, pairs in per_image.items():
            buckets: dict[str, list[float]] = defaultdict(list)
            for sample_id, value in pairs:
                buckets[group_of[str(sample_id)]].append(value)
            if buckets:
                result[f"{name}{CAPTURE_GROUP_SUFFIX}"] = float(
                    np.mean([float(np.mean(values)) for values in buckets.values()])
                )
        result["capture_groups"] = float(
            len({group_of[str(sample_id)] for pairs in per_image.values() for sample_id, _ in pairs})
        )
    result["samples_per_second"] = sample_count / elapsed
    result["samples"] = float(sample_count)
    return result


def rng_state(loader: DataLoader) -> dict[str, Any]:
    if loader.persistent_workers:
        raise RuntimeError(
            "persistent DataLoader workers make augmentation RNG impossible to "
            "restore exactly; reproducible checkpoints require them to be disabled"
        )
    state: dict[str, Any] = {
        "python": random.getstate(),
        "numpy": np.random.get_state(),
        "torch": torch.get_rng_state(),
        "train_loader_generator": loader.generator.get_state(),
    }
    if torch.cuda.is_available():
        state["cuda"] = torch.cuda.get_rng_state_all()
    return state


def restore_rng_state(state: dict[str, Any], loader: DataLoader) -> None:
    random.setstate(state["python"])
    np.random.set_state(state["numpy"])
    torch.set_rng_state(state["torch"])
    loader.generator.set_state(state["train_loader_generator"])
    if torch.cuda.is_available() and "cuda" in state:
        torch.cuda.set_rng_state_all(state["cuda"])


def cv_fold_identity(config: Config) -> dict[str, str]:
    """Freeze id and hash of the fold partition a run was cut against."""
    if config.fold is None and config.production_selection_fold is None:
        return {}
    path = Path(config.dataset_root) / "splits" / CV_FOLDS_NAME
    return {
        "cv_folds_freeze_id": str(json.loads(path.read_text())["freeze_id"]),
        "cv_folds_sha256": sha256_file(path),
    }


def save_checkpoint(
    path: Path,
    model: torch.nn.Module,
    optimizer: AdamW,
    scheduler: torch.optim.lr_scheduler.LRScheduler,
    epoch: int,
    validation_metrics: dict[str, float],
    best_metrics: dict[str, float],
    config: Config,
    train_loader: DataLoader,
    selection_loader: DataLoader,
    run_identity: dict[str, object] | None = None,
    initial_checkpoint_sha256: str | None = None,
) -> None:
    raw_model = getattr(model, "_orig_mod", model)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    identity = checkpoint_identity(config) if run_identity is None else run_identity
    current_identity = checkpoint_identity(config)
    if identity != current_identity:
        raise RuntimeError(
            "Dataset/config identity changed after the run loaded its samples; "
            "refusing to stamp a checkpoint with bytes it did not train on"
        )
    torch.save(
        {
            "model": raw_model.state_dict(),
            "optimizer": optimizer.state_dict(),
            "scheduler": scheduler.state_dict(),
            "epoch": epoch,
            "validation_metrics": validation_metrics,
            "primary_metric": primary_metric_name(config.model),
            "validation_primary": validation_metrics[primary_metric_name(config.model)],
            "best_metrics": best_metrics,
            "rng_state": rng_state(train_loader),
            "config": asdict(config),
            "initial_checkpoint_sha256": initial_checkpoint_sha256,
            **identity,
            "label_contract_id": (
                LABEL_CONTRACT_ID if not config.allow_legacy_label_schema else "hyperdr.apple-gain-label/v1"
            ),
            # H1: the run carries the provenance of the samples it was fit to,
            # so evaluation can refuse a checkpoint scored against other bytes
            # and a report can name its own domain mix without consulting a
            # manifest that may since have changed.
            "provenance_digest": train_loader.dataset.provenance_digest,
            # Epoch/checkpoint selection is computed on this second dataset.
            # Authenticating only the training rows would still allow fold 4
            # (or validation.json) to drift while an old best.pt looked valid.
            "selection_provenance_digest": (
                selection_loader.dataset.provenance_digest
            ),
            # Without this, editing the fold file would silently change which
            # samples `--fold 4` names while old checkpoints still pass every
            # other check.
            **cv_fold_identity(config),
        },
        temp,
    )
    os.replace(temp, path)


def validate_resume_config(
    config: Config,
    checkpoint: dict[str, Any],
    provenance_digest: dict[str, object] | None = None,
    selection_provenance_digest: dict[str, object] | None = None,
) -> None:
    saved = checkpoint["config"]
    immutable = (
        "dataset_root",
        "input_cache_dir",
        "target_cache_dir",
        "label_subset",
        "target_mode",
        "model",
        "architecture",
        "epochs",
        "batch_size",
        "learning_rate",
        "weight_decay",
        "base_channels",
        "seed",
        "fold",
        "selection_fold",
        "production_selection_fold",
        "highlight_weight",
        "batch_by_shape",
        "lambda_gain_min",
        "lambda_gain_max",
        "lambda_reconstructed_gain",
        "lambda_gradient",
        "lambda_global_mean",
        "allow_legacy_label_schema",
    )
    # Defaults stand in for fields older checkpoints predate, so resuming one
    # of those does not report a mismatch against a key it never had.
    resume_defaults = {
        "architecture": "baseline",
        "allow_legacy_label_schema": True,
        "model": "map_only",
        "fold": None,
        "selection_fold": None,
        "production_selection_fold": None,
        "input_cache_dir": None,
        "target_cache_dir": None,
        "initialize_from_checkpoint": None,
        "batch_by_shape": False,
        "lambda_gain_min": 1.0,
        "lambda_gain_max": 1.0,
        "lambda_reconstructed_gain": 1.0,
        "lambda_gradient": DEFAULT_GRADIENT_WEIGHT,
        "lambda_global_mean": DEFAULT_GLOBAL_MEAN_WEIGHT,
    }
    mismatches = {
        name: (saved.get(name), getattr(config, name))
        for name in immutable
        if saved.get(name, resume_defaults.get(name)) != getattr(config, name)
    }
    if mismatches:
        raise ValueError(f"Resume configuration mismatch: {mismatches}")
    if "config_sha256" not in checkpoint:
        raise ValueError(
            "Checkpoint carries no config_sha256; it predates the complete "
            "reproducibility-config stamp and cannot resume"
        )
    saved_config_sha256 = config_sha256(saved)
    if checkpoint["config_sha256"] != saved_config_sha256:
        raise ValueError(
            "Checkpoint config_sha256 does not match its embedded config; the "
            "checkpoint metadata is internally inconsistent"
        )
    current_config_sha256 = config_sha256(config)
    if checkpoint["config_sha256"] != current_config_sha256:
        saved_repro = reproducibility_config(saved)
        current_repro = reproducibility_config(config)
        changed = sorted(
            name
            for name in saved_repro.keys() | current_repro.keys()
            if saved_repro.get(name) != current_repro.get(name)
        )
        raise ValueError(
            "Resume reproducibility configuration hash mismatch; changed field(s): "
            + ", ".join(changed)
        )
    for required in ("scheduler", "rng_state", "best_metrics"):
        if required not in checkpoint:
            raise ValueError(
                f"Checkpoint lacks {required}; only new full-state checkpoints can resume"
            )
    expected_contract = "hyperdr.apple-gain-label/v1" if config.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise ValueError("Checkpoint label contract does not match the requested schema gate")
    # H6: these are presence-required, not presence-conditional.  A check
    # written as "if the field is there, compare it" certifies every checkpoint
    # that predates the field -- exactly the ones whose comparability nothing
    # else establishes -- and it does so silently.
    expected_manifest = sha256_file(Path(config.dataset_root) / "manifests" / "samples.jsonl")
    if "manifest_sha256" not in checkpoint:
        raise ValueError(
            "Checkpoint carries no manifest_sha256; it predates the dataset "
            "identity stamp and cannot be shown to match this corpus"
        )
    if checkpoint["manifest_sha256"] != expected_manifest:
        raise ValueError("Checkpoint manifest hash does not match the dataset")
    if config.input_cache_dir is not None:
        cache_manifest = Path(config.input_cache_dir) / "deployment-cache.jsonl"
        expected_cache = sha256_file(cache_manifest)
        if checkpoint.get("deployment_cache_manifest_sha256") != expected_cache:
            raise ValueError(
                "Checkpoint deployment-cache manifest hash does not match the "
                "paired input/target cache"
            )
    expected_splits = split_file_hashes(config)
    stored_splits = checkpoint.get("split_sha256")
    if not isinstance(stored_splits, dict):
        raise ValueError(
            "Checkpoint carries no split_sha256 mapping; it cannot prove which "
            "train/validation/test/group partition defined the run"
        )
    if stored_splits != expected_splits:
        changed = sorted(
            name
            for name in stored_splits.keys() | expected_splits.keys()
            if stored_splits.get(name) != expected_splits.get(name)
        )
        raise ValueError(
            "Checkpoint split hashes do not match the dataset; changed file(s): "
            + ", ".join(changed)
        )
    for name, expected in cv_fold_identity(config).items():
        if name not in checkpoint:
            raise ValueError(
                f"Checkpoint carries no {name}; a fold run cannot resume without "
                "it, because nothing else pins which samples its fold index names"
            )
        if checkpoint[name] != expected:
            raise ValueError(
                f"Checkpoint {name} does not match the dataset; the fold partition "
                "changed, so the same fold index no longer names the same samples"
            )
    if provenance_digest is not None:
        compare_digests(
            checkpoint.get("provenance_digest"),
            provenance_digest,
            what="the checkpoint being resumed",
        )
    if not isinstance(checkpoint.get("selection_provenance_digest"), dict):
        raise ValueError(
            "Checkpoint carries no selection_provenance_digest; it cannot prove "
            "which samples selected its epoch/checkpoint"
        )
    if selection_provenance_digest is not None:
        compare_digests(
            checkpoint["selection_provenance_digest"],
            selection_provenance_digest,
            what="the checkpoint selection split",
        )


def main() -> None:
    config = parse_args()
    configure_deterministic_execution()
    seed_everything(config.seed)
    if not torch.cuda.is_available():
        raise SystemExit("CUDA is required for training")
    device = torch.device("cuda")

    output = Path(config.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    history_path = output / "history.jsonl"
    if config.resume is None and history_path.exists():
        raise SystemExit(
            f"{history_path} already exists; use a new output directory or --resume"
        )

    # Capture before constructing any dataset, then require these exact bytes
    # at every checkpoint.  Re-hashing only while saving could stamp a mutated
    # manifest/split even though the in-memory loader still holds the old rows.
    run_identity = checkpoint_identity(config)
    train_loader = make_loader(config, "train", augment=True)
    # With --fold, the scored split is the SELECTION fold, not the judgment
    # fold. Everything this run chooses -- epoch, best.pt -- is chosen on data
    # that is not in the judgment set.
    validation_loader = make_loader(
        config,
        "holdout"
        if config.fold is not None or config.production_selection_fold is not None
        else "validation",
        augment=False,
    )
    if config.fold is not None:
        # Structural guard rather than a convention: if the judgment fold ever
        # appears in either loader, the run's scores are contaminated and the
        # resulting OOF estimate is void.  Read membership only from the
        # frozen CV registry: constructing a judgment-fold Dataset here would
        # parse its labels/provenance before the checkpoint is committed.
        fold_record = json.loads(
            (Path(config.dataset_root) / "splits" / CV_FOLDS_NAME).read_text(
                encoding="utf-8"
            )
        )
        judgment = {
            str(sample_id)
            for sample_id, fold in fold_record["sample_fold"].items()
            if int(fold) == config.fold
        }
        if not judgment:
            raise SystemExit(f"judgment fold {config.fold} has no registered members")
        for name, loader in (("train", train_loader), ("selection", validation_loader)):
            seen = {str(row["sample_id"]) for row in loader.dataset.rows}
            overlap = seen & judgment
            if overlap:
                raise SystemExit(
                    f"{len(overlap)} judgment-fold sample(s) leaked into the {name} "
                    f"split (first: {sorted(overlap)[0]})"
                )
    if config.production_selection_fold is not None:
        train_ids = {str(row["sample_id"]) for row in train_loader.dataset.rows}
        selection_ids = {
            str(row["sample_id"]) for row in validation_loader.dataset.rows
        }
        overlap = train_ids & selection_ids
        if overlap:
            raise SystemExit(
                "production training overlaps its checkpoint-selection fold "
                f"(first: {sorted(overlap)[0]})"
            )
        from hyperdr_ml.protocol import AppleProtocolCorpus

        registered_selection = set(
            AppleProtocolCorpus(Path(config.dataset_root)).ids_for_folds(
                [config.production_selection_fold], domain=config.label_subset
            )
        )
        if selection_ids != registered_selection:
            raise SystemExit(
                "production checkpoint-selection membership does not match the "
                "frozen CV registry"
            )
    train_audit = target_statistics(train_loader.dataset)
    validation_audit = target_statistics(validation_loader.dataset)
    target_policy = {
        "fixed_3stops": (
            "divide by a fixed 3 stops, clip outside [0, 1], and report both "
            "saturated and below-range pixels"
        ),
        "iso_interval": (
            "normalize by each file's declared ISO interval: "
            "M = (G - gain_min) / (gain_max - gain_min); in [0, 1] by the label "
            "contract, so saturated and below-range counts are expected to be zero"
        ),
        "per_image": "normalize by each eligible image maximum; degenerate images excluded",
        "signed_stops": (
            "raw signed log2 gain in stops, no normalization and no clip; the "
            "control model must see the same quantity the interval model rebuilds"
        ),
    }
    target_audit = {
        "label_contract_id": train_loader.dataset.label_contract_id,
        "model": config.model,
        "policy": target_policy[config.target_mode],
        "train": train_audit,
        "validation": validation_audit,
        # H1/H2: the domain and writer-profile composition of each split, next
        # to the numbers computed from it.  A mixed run is not forbidden, but it
        # has to be legible from its own outputs and reversible out of them.
        "provenance": {
            "train": train_loader.dataset.provenance_digest,
            "validation": validation_loader.dataset.provenance_digest,
        },
    }
    (output / "target-audit.json").write_text(
        json.dumps(target_audit, indent=2) + "\n"
    )

    raw_model = build_model(config).to(device)
    initial_output_bias = None
    initial_metadata_bias = None
    checkpoint = None
    initial_checkpoint_sha256 = None
    if config.resume:
        checkpoint = torch.load(
            config.resume, map_location="cpu", weights_only=False
        )
        validate_resume_config(
            config,
            checkpoint,
            train_loader.dataset.provenance_digest,
            validation_loader.dataset.provenance_digest,
        )
        raw_model.load_state_dict(checkpoint["model"])
        initial_checkpoint_sha256 = checkpoint.get("initial_checkpoint_sha256")
    elif config.initialize_from_checkpoint:
        initial_checkpoint = torch.load(
            config.initialize_from_checkpoint, map_location="cpu", weights_only=False
        )
        initial_config = initial_checkpoint.get("config")
        if not isinstance(initial_config, dict):
            raise SystemExit("initial checkpoint has no config mapping")
        required_match = {
            "model": config.model,
            "target_mode": config.target_mode,
            "architecture": config.architecture,
            "base_channels": config.base_channels,
        }
        mismatches = {
            name: (initial_config.get(name), expected)
            for name, expected in required_match.items()
            if initial_config.get(name, "baseline" if name == "architecture" else None)
            != expected
        }
        expected_contract = (
            "hyperdr.apple-gain-label/v1"
            if config.allow_legacy_label_schema
            else LABEL_CONTRACT_ID
        )
        if initial_checkpoint.get("label_contract_id") != expected_contract:
            mismatches["label_contract_id"] = (
                initial_checkpoint.get("label_contract_id"), expected_contract
            )
        if mismatches:
            raise SystemExit(
                f"initial checkpoint is incompatible with this model contract: {mismatches}"
            )
        raw_model.load_state_dict(initial_checkpoint["model"], strict=True)
        initial_checkpoint_sha256 = sha256_file(
            Path(config.initialize_from_checkpoint)
        )
    elif config.initialize_output_bias:
        initial_output_bias = raw_model.initialize_output_bias(
            float(train_audit["masked_target_mean"])
        )
        if config.model == "interval":
            # Start the endpoints at the corpus means so the first steps are
            # not spent walking a linear head in from zero.
            initial_metadata_bias = raw_model.initialize_metadata_bias(
                float(train_audit["mean_gain_min"]),
                float(train_audit["mean_gain_range"]),
            )
    parameter_count = sum(parameter.numel() for parameter in raw_model.parameters())
    model: torch.nn.Module = (
        torch.compile(raw_model) if config.compile_model else raw_model
    )
    optimizer = AdamW(
        model.parameters(),
        lr=config.learning_rate,
        weight_decay=config.weight_decay,
    )
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer,
        T_max=config.epochs,
        eta_min=config.learning_rate * 0.05,
    )

    start_epoch = 1
    group_of = capture_group_map(config.dataset_root)
    primary_name = primary_metric_name(config.model)
    secondary_name = secondary_metric_name(config.model, config.target_mode)
    best_metrics = {primary_name: float("inf"), secondary_name: float("inf")}
    if checkpoint is not None:
        optimizer.load_state_dict(checkpoint["optimizer"])
        scheduler.load_state_dict(checkpoint["scheduler"])
        restore_rng_state(checkpoint["rng_state"], train_loader)
        start_epoch = int(checkpoint["epoch"]) + 1
        best_metrics = {
            name: float(value)
            for name, value in checkpoint["best_metrics"].items()
        }
    if start_epoch > config.epochs:
        raise SystemExit(
            f"Checkpoint epoch {start_epoch - 1} already reached configured "
            f"{config.epochs} epochs"
        )

    (output / "config.json").write_text(
        json.dumps(asdict(config), indent=2) + "\n"
    )
    print(
        json.dumps(
            {
                "device": torch.cuda.get_device_name(0),
                "parameters": parameter_count,
                "initial_output_bias": initial_output_bias,
                "initial_metadata_bias": initial_metadata_bias,
                "initial_checkpoint_sha256": initial_checkpoint_sha256,
                "primary_metric": primary_name,
                "train_samples": len(train_loader.dataset),
                "validation_samples": len(validation_loader.dataset),
                "target_audit": target_audit,
                "start_epoch": start_epoch,
                "config": asdict(config),
            },
            indent=2,
        ),
        flush=True,
    )

    highlight_checkpoint_name = (
        "best-relative-high-gain.pt"
        if secondary_name == "relative_high_gain_mae"
        else "best-absolute-highlight.pt"
    )
    for epoch in range(start_epoch, config.epochs + 1):
        torch.cuda.reset_peak_memory_stats(device)
        current_learning_rate = float(optimizer.param_groups[0]["lr"])
        train_metrics = run_epoch(model, train_loader, optimizer, device, config, group_of)
        validation_metrics = run_epoch(
            model, validation_loader, None, device, config, group_of
        )
        if not all(
            math.isfinite(value)
            for metrics in (train_metrics, validation_metrics)
            for value in metrics.values()
        ):
            raise FloatingPointError("Non-finite epoch metric")

        improved_mae = validation_metrics[primary_name] < best_metrics[primary_name]
        improved_highlight = (
            validation_metrics[secondary_name] < best_metrics[secondary_name]
        )
        if improved_mae:
            best_metrics[primary_name] = validation_metrics[primary_name]
        if improved_highlight:
            best_metrics[secondary_name] = validation_metrics[secondary_name]

        scheduler.step()
        record = {
            "epoch": epoch,
            "learning_rate": current_learning_rate,
            "next_learning_rate": float(optimizer.param_groups[0]["lr"]),
            "train": train_metrics,
            "validation": validation_metrics,
            "peak_vram_gib": torch.cuda.max_memory_allocated(device) / 2**30,
        }
        with history_path.open("a") as handle:
            handle.write(json.dumps(record) + "\n")
        print(json.dumps(record), flush=True)

        save_checkpoint(
            output / "last.pt",
            model,
            optimizer,
            scheduler,
            epoch,
            validation_metrics,
            best_metrics,
            config,
            train_loader,
            validation_loader,
            run_identity,
            initial_checkpoint_sha256,
        )
        if improved_mae:
            save_checkpoint(
                output / "best.pt",
                model,
                optimizer,
                scheduler,
                epoch,
                validation_metrics,
                best_metrics,
                config,
                train_loader,
                validation_loader,
                run_identity,
                initial_checkpoint_sha256,
            )
        if improved_highlight:
            save_checkpoint(
                output / highlight_checkpoint_name,
                model,
                optimizer,
                scheduler,
                epoch,
                validation_metrics,
                best_metrics,
                config,
                train_loader,
                validation_loader,
                run_identity,
                initial_checkpoint_sha256,
            )
    print(
        json.dumps({"completed": True, "best_validation": best_metrics}),
        flush=True,
    )


if __name__ == "__main__":
    main()
