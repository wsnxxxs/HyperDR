#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import nullcontext
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
    AppleGainMapDataset,
    TargetMode,
    collate_gain_maps,
    target_statistics,
)
from hyperdr_ml.loss import gain_loss
from hyperdr_ml.model import Architecture, DirectGainMapNet
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file


@dataclass
class Config:
    dataset_root: str
    output_dir: str
    label_subset: str
    target_mode: TargetMode
    architecture: Architecture
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
    allow_legacy_label_schema: bool


def parse_args() -> Config:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dataset-root", default=str(Path.home() / "datasets/hyperdr-apple")
    )
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--label-subset",
        choices=("iso_native", "legacy_apple", "all", "xmp"),
        default="iso_native",
    )
    parser.add_argument(
        "--target-mode",
        choices=("per_image", "fixed_3stops"),
        default="fixed_3stops",
    )
    parser.add_argument(
        "--architecture",
        choices=("baseline", "global_conditioning", "dilation_pyramid"),
        default="baseline",
    )
    parser.add_argument("--epochs", type=int, default=80)
    parser.add_argument("--batch-size", type=int, default=8)
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
        "--allow-legacy-label-schema",
        action="store_true",
        help="explicitly reproduce the frozen v1 normalized/f16 labels",
    )
    parser.set_defaults(initialize_output_bias=True)
    values = parser.parse_args()
    if values.epochs <= 0 or values.batch_size <= 0:
        parser.error("--epochs and --batch-size must be positive")
    if values.base_channels <= 0 or values.num_workers < 0:
        parser.error("--base-channels must be positive and --num-workers non-negative")
    return Config(**vars(values))


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)


def make_loader(config: Config, split: str, augment: bool) -> DataLoader:
    dataset = AppleGainMapDataset(
        config.dataset_root,
        split,
        config.label_subset,
        augment,
        config.target_mode,
        allow_legacy_label_schema=config.allow_legacy_label_schema,
    )
    generator = torch.Generator().manual_seed(
        config.seed + (0 if split == "train" else 1)
    )
    return DataLoader(
        dataset,
        batch_size=config.batch_size,
        shuffle=split == "train",
        num_workers=config.num_workers,
        pin_memory=True,
        persistent_workers=config.num_workers > 0,
        collate_fn=collate_gain_maps,
        generator=generator,
    )


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast(device_type="cuda", dtype=torch.bfloat16)
    return nullcontext()


def highlight_metric_name(target_mode: TargetMode) -> str:
    return (
        "absolute_highlight_mae_stops"
        if target_mode == "fixed_3stops"
        else "relative_high_gain_mae"
    )


def run_epoch(
    model: torch.nn.Module,
    loader: DataLoader,
    optimizer: AdamW | None,
    device: torch.device,
    highlight_weight: float,
    target_mode: TargetMode,
) -> dict[str, float]:
    training = optimizer is not None
    model.train(training)
    totals = defaultdict(float)
    weights = defaultdict(float)
    sample_count = 0
    start = time.perf_counter()
    highlight_name = highlight_metric_name(target_mode)
    for batch in loader:
        sdr = batch["sdr"].to(device, non_blocking=True)
        target = batch["target"].to(device, non_blocking=True)
        mask = batch["mask"].to(device, non_blocking=True)
        if optimizer is not None:
            optimizer.zero_grad(set_to_none=True)
        with torch.set_grad_enabled(training), autocast_context(device):
            prediction = model(sdr)
            loss, metrics = gain_loss(
                prediction.float(),
                target,
                mask,
                highlight_weight,
                target_mode,
            )
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
        count = int(sdr.shape[0])
        sample_count += count
        highlight_images = float(metrics["_highlight_valid_images"])
        zero_target_images = float(metrics["_zero_target_valid_images"])
        for name, value in metrics.items():
            if name.startswith("_"):
                continue
            if name == highlight_name:
                weight = highlight_images
            elif name == "false_high_prediction_rate_on_zero_target":
                weight = zero_target_images
            else:
                weight = count
            if weight:
                totals[name] += float(value) * weight
                weights[name] += weight
    elapsed = time.perf_counter() - start
    result = {
        name: totals[name] / weights[name] for name in sorted(totals)
    }
    result["samples_per_second"] = sample_count / elapsed
    result["samples"] = float(sample_count)
    return result


def rng_state(loader: DataLoader) -> dict[str, Any]:
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
) -> None:
    raw_model = getattr(model, "_orig_mod", model)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    torch.save(
        {
            "model": raw_model.state_dict(),
            "optimizer": optimizer.state_dict(),
            "scheduler": scheduler.state_dict(),
            "epoch": epoch,
            "validation_metrics": validation_metrics,
            "validation_mae": validation_metrics["mae"],
            "best_metrics": best_metrics,
            "rng_state": rng_state(train_loader),
            "config": asdict(config),
            "label_contract_id": (
                LABEL_CONTRACT_ID if not config.allow_legacy_label_schema else "hyperdr.apple-gain-label/v1"
            ),
            "manifest_sha256": sha256_file(
                Path(config.dataset_root) / "manifests" / "samples.jsonl"
            ),
        },
        temp,
    )
    os.replace(temp, path)


def validate_resume_config(config: Config, checkpoint: dict[str, Any]) -> None:
    saved = checkpoint["config"]
    immutable = (
        "dataset_root",
        "label_subset",
        "target_mode",
        "architecture",
        "epochs",
        "batch_size",
        "learning_rate",
        "weight_decay",
        "base_channels",
        "seed",
        "highlight_weight",
        "allow_legacy_label_schema",
    )
    mismatches = {
        name: (saved.get(name), getattr(config, name))
        for name in immutable
        if saved.get(
            name,
            "baseline" if name == "architecture" else (True if name == "allow_legacy_label_schema" else None),
        )
        != getattr(config, name)
    }
    if mismatches:
        raise ValueError(f"Resume configuration mismatch: {mismatches}")
    for required in ("scheduler", "rng_state", "best_metrics"):
        if required not in checkpoint:
            raise ValueError(
                f"Checkpoint lacks {required}; only new full-state checkpoints can resume"
            )
    expected_contract = "hyperdr.apple-gain-label/v1" if config.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise ValueError("Checkpoint label contract does not match the requested schema gate")
    expected_manifest = sha256_file(Path(config.dataset_root) / "manifests" / "samples.jsonl")
    if "manifest_sha256" in checkpoint and checkpoint.get("manifest_sha256") != expected_manifest:
        raise ValueError("Checkpoint manifest hash does not match the dataset")


def main() -> None:
    config = parse_args()
    seed_everything(config.seed)
    torch.backends.cudnn.benchmark = True
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

    train_loader = make_loader(config, "train", augment=True)
    validation_loader = make_loader(config, "validation", augment=False)
    train_audit = target_statistics(train_loader.dataset)
    validation_audit = target_statistics(validation_loader.dataset)
    target_audit = {
        "policy": (
            "clip gain above 3 stops and report sample/pixel saturation"
            if config.target_mode == "fixed_3stops"
            else "normalize by each eligible image maximum; degenerate images excluded"
        ),
        "train": train_audit,
        "validation": validation_audit,
    }
    (output / "target-audit.json").write_text(
        json.dumps(target_audit, indent=2) + "\n"
    )

    raw_model = DirectGainMapNet(config.base_channels, config.architecture).to(device)
    initial_output_bias = None
    checkpoint = None
    if config.resume:
        checkpoint = torch.load(
            config.resume, map_location="cpu", weights_only=False
        )
        validate_resume_config(config, checkpoint)
        raw_model.load_state_dict(checkpoint["model"])
    elif config.initialize_output_bias:
        initial_output_bias = raw_model.initialize_output_bias(
            float(train_audit["masked_target_mean"])
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
    best_metrics = {
        "mae": float("inf"),
        highlight_metric_name(config.target_mode): float("inf"),
    }
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

    highlight_name = highlight_metric_name(config.target_mode)
    highlight_checkpoint_name = (
        "best-absolute-highlight.pt"
        if config.target_mode == "fixed_3stops"
        else "best-relative-high-gain.pt"
    )
    for epoch in range(start_epoch, config.epochs + 1):
        torch.cuda.reset_peak_memory_stats(device)
        current_learning_rate = float(optimizer.param_groups[0]["lr"])
        train_metrics = run_epoch(
            model,
            train_loader,
            optimizer,
            device,
            config.highlight_weight,
            config.target_mode,
        )
        validation_metrics = run_epoch(
            model,
            validation_loader,
            None,
            device,
            config.highlight_weight,
            config.target_mode,
        )
        if not all(
            math.isfinite(value)
            for metrics in (train_metrics, validation_metrics)
            for value in metrics.values()
        ):
            raise FloatingPointError("Non-finite epoch metric")

        improved_mae = validation_metrics["mae"] < best_metrics["mae"]
        improved_highlight = (
            validation_metrics[highlight_name] < best_metrics[highlight_name]
        )
        if improved_mae:
            best_metrics["mae"] = validation_metrics["mae"]
        if improved_highlight:
            best_metrics[highlight_name] = validation_metrics[highlight_name]

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
            )
    print(
        json.dumps({"completed": True, "best_validation": best_metrics}),
        flush=True,
    )


if __name__ == "__main__":
    main()
