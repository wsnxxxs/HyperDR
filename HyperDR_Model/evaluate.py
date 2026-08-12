#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import nullcontext
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from hyperdr_ml.data import AppleGainMapDataset, collate_gain_maps
from hyperdr_ml.model import DirectGainMapNet


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast("cuda", dtype=torch.bfloat16)
    return nullcontext()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--split", default="test", choices=("validation", "test"))
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    dataset = AppleGainMapDataset(
        config["dataset_root"],
        args.split,
        config["label_subset"],
        False,
        config.get("target_mode", "per_image"),
    )
    loader = DataLoader(dataset, batch_size=8, num_workers=4, collate_fn=collate_gain_maps)
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda was requested but CUDA is unavailable")
    device = torch.device(
        "cuda"
        if args.device == "cuda"
        or (args.device == "auto" and torch.cuda.is_available())
        else "cpu"
    )
    model = DirectGainMapNet(
        config["base_channels"], config.get("architecture", "baseline")
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()

    sample_mae = []
    model_sum_abs = 0.0
    zero_sum_abs = 0.0
    half_sum_abs = 0.0
    train_mean_sum_abs = 0.0
    pixel_count = 0.0

    train_dataset = AppleGainMapDataset(
        config["dataset_root"],
        "train",
        config["label_subset"],
        False,
        config.get("target_mode", "per_image"),
    )
    train_loader = DataLoader(
        train_dataset, batch_size=8, num_workers=4, collate_fn=collate_gain_maps
    )
    train_sum = 0.0
    train_count = 0.0
    for batch in train_loader:
        train_sum += float((batch["target"] * batch["mask"]).sum())
        train_count += float(batch["mask"].sum())
    train_mean = train_sum / train_count

    with torch.inference_mode():
        for batch in loader:
            sdr = batch["sdr"].to(device, non_blocking=device.type == "cuda")
            with autocast_context(device):
                prediction = model(sdr).float().cpu()
            target = batch["target"]
            mask = batch["mask"]
            model_sum_abs += float(((prediction - target).abs() * mask).sum())
            zero_sum_abs += float((target.abs() * mask).sum())
            half_sum_abs += float(((target - 0.5).abs() * mask).sum())
            train_mean_sum_abs += float(
                ((target - train_mean).abs() * mask).sum()
            )
            pixel_count += float(mask.sum())
            for index, sample_id in enumerate(batch["sample_id"]):
                valid = mask[index].bool()
                sample_mae.append({
                    "sample_id": sample_id,
                    "normalized_gain_mae": float((prediction[index][valid] - target[index][valid]).abs().mean()),
                })

    baselines = {
        "zero": zero_sum_abs / pixel_count,
        "half": half_sum_abs / pixel_count,
        "train_mean": train_mean_sum_abs / pixel_count,
    }
    model_mae = model_sum_abs / pixel_count
    target_mode = config.get("target_mode", "per_image")
    report = {
        "split": args.split,
        "samples": len(dataset),
        "checkpoint_epoch": checkpoint["epoch"],
        "device": str(device),
        "target_mode": target_mode,
        "metric_scope": (
            "per-pixel normalized absolute gain in a fixed 0-3 stop range"
            if target_mode == "fixed_3stops"
            else "per-pixel relative gain placement normalized by per-image maximum"
        ),
        "model_normalized_gain_mae": model_mae,
        "baselines": baselines,
        "relative_improvement_vs_train_mean": (baselines["train_mean"] - model_mae) / baselines["train_mean"],
        "sample_mae_mean": sum(item["normalized_gain_mae"] for item in sample_mae) / len(sample_mae),
        "sample_mae_min": min(item["normalized_gain_mae"] for item in sample_mae),
        "sample_mae_max": max(item["normalized_gain_mae"] for item in sample_mae),
        "limitation": (
            "The fixed-scale target clips gain above 3 stops."
            if target_mode == "fixed_3stops"
            else "Per-image targets require ground-truth headroom and do not infer absolute HDR strength."
        ),
        "per_sample": sample_mae,
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "per_sample"}, indent=2))


if __name__ == "__main__":
    main()
