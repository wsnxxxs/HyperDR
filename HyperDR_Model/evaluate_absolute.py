#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import defaultdict
from contextlib import nullcontext
import json
from pathlib import Path

import torch
from torch.utils.data import DataLoader

from hyperdr_ml.data import (
    FIXED_GAIN_STOPS,
    AppleGainMapDataset,
    collate_gain_maps,
)
from hyperdr_ml.model import DirectGainMapNet
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file


def accumulator() -> dict[str, float]:
    return {
        "sum_abs": 0.0,
        "count": 0.0,
        "samples": 0.0,
        "mean_abs": 0.0,
        "p95_abs": 0.0,
    }


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast("cuda", dtype=torch.bfloat16)
    return nullcontext()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--split", choices=("validation", "test"), default="test")
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument("--allow-legacy-label-schema", action="store_true")
    args = parser.parse_args()
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    expected_contract = "hyperdr.apple-gain-label/v1" if args.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise SystemExit("checkpoint label contract is not permitted by the schema gate")
    if config.get("target_mode") != "fixed_3stops":
        raise SystemExit("This evaluator requires fixed_3stops targets")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda was requested but CUDA is unavailable")
    device = torch.device(
        "cuda"
        if args.device == "cuda"
        or (args.device == "auto" and torch.cuda.is_available())
        else "cpu"
    )

    root = Path(config["dataset_root"])
    if "manifest_sha256" in checkpoint and checkpoint.get("manifest_sha256") != sha256_file(root / "manifests" / "samples.jsonl"):
        raise SystemExit("checkpoint manifest hash does not match its dataset")
    manifest = {
        row["sample_id"]: row
        for row in (
            json.loads(line)
            for line in (root / "manifests" / "samples.jsonl")
            .read_text()
            .splitlines()
        )
    }
    dataset = AppleGainMapDataset(
        root, args.split, config["label_subset"], False, "fixed_3stops",
        allow_legacy_label_schema=args.allow_legacy_label_schema,
    )
    loader = DataLoader(
        dataset, batch_size=8, num_workers=4, collate_fn=collate_gain_maps
    )
    train_dataset = AppleGainMapDataset(
        root, "train", config["label_subset"], False, "fixed_3stops",
        allow_legacy_label_schema=args.allow_legacy_label_schema,
    )
    train_loader = DataLoader(
        train_dataset, batch_size=8, num_workers=4, collate_fn=collate_gain_maps
    )
    train_sum = 0.0
    train_count = 0.0
    for batch in train_loader:
        train_sum += float((batch["target"] * batch["mask"]).sum())
        train_count += float(batch["mask"].sum())
    train_mean_stops = train_sum / train_count * FIXED_GAIN_STOPS

    model = DirectGainMapNet(
        config["base_channels"], config.get("architecture", "baseline")
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()

    buckets = defaultdict(accumulator)
    samples = []
    constant_sum_abs = 0.0
    constant_count = 0
    with torch.inference_mode():
        for batch in loader:
            with autocast_context(device):
                prediction = (
                    model(
                        batch["sdr"].to(
                            device, non_blocking=device.type == "cuda"
                        )
                    )
                    .float()
                    .cpu()
                    * FIXED_GAIN_STOPS
                )
            target = batch["target"] * FIXED_GAIN_STOPS
            mask = batch["mask"].bool()
            constant_error = (target[mask] - train_mean_stops).abs()
            constant_sum_abs += float(constant_error.sum())
            constant_count += constant_error.numel()

            for index, sample_id in enumerate(batch["sample_id"]):
                valid = mask[index]
                predicted = prediction[index][valid]
                expected = target[index][valid]
                error = (predicted - expected).abs()
                row = manifest[sample_id]
                source = (
                    "xmp"
                    if row["headroom_source"] == "xmp_hdr_gain_map_headroom"
                    else "legacy"
                )
                sample = {
                    "sample_id": sample_id,
                    "headroom_source": source,
                    "mae_stops": float(error.mean()),
                    "target_mean_stops": float(expected.mean()),
                    "prediction_mean_stops": float(predicted.mean()),
                    "target_p95_stops": float(torch.quantile(expected, 0.95)),
                    "prediction_p95_stops": float(
                        torch.quantile(predicted, 0.95)
                    ),
                }
                samples.append(sample)
                for name in ("all", source):
                    bucket = buckets[name]
                    bucket["sum_abs"] += float(error.sum())
                    bucket["count"] += error.numel()
                    bucket["samples"] += 1
                    bucket["mean_abs"] += abs(
                        sample["prediction_mean_stops"]
                        - sample["target_mean_stops"]
                    )
                    bucket["p95_abs"] += abs(
                        sample["prediction_p95_stops"]
                        - sample["target_p95_stops"]
                    )
                for name, selection in (
                    ("low_0_to_1_stop", expected < 1.0),
                    (
                        "hdr_1_to_2_stops",
                        (expected >= 1.0) & (expected < 2.0),
                    ),
                    ("hdr_2_to_3_stops", expected >= 2.0),
                ):
                    selected_error = error[selection]
                    buckets[name]["sum_abs"] += float(selected_error.sum())
                    buckets[name]["count"] += selected_error.numel()

    constant_mae = constant_sum_abs / constant_count
    bucket_report = {}
    for name, value in buckets.items():
        report = {
            "pixel_count": int(value["count"]),
            "pixel_mae_stops": (
                value["sum_abs"] / value["count"] if value["count"] else None
            ),
        }
        if value["samples"]:
            report.update(
                {
                    "samples": int(value["samples"]),
                    "per_image_mean_gain_mae_stops": value["mean_abs"]
                    / value["samples"],
                    "per_image_p95_gain_mae_stops": value["p95_abs"]
                    / value["samples"],
                }
            )
        bucket_report[name] = report

    overall_mae = bucket_report["all"]["pixel_mae_stops"]
    result = {
        "checkpoint_epoch": checkpoint["epoch"],
        "split": args.split,
        "samples": len(dataset),
        "device": str(device),
        "target": "absolute log2 gain in fixed 0-3 stop range",
        "buckets": bucket_report,
        "train_mean_constant_baseline_stops": train_mean_stops,
        "train_mean_constant_pixel_mae_stops": constant_mae,
        "relative_improvement_vs_constant": (
            (constant_mae - overall_mae) / constant_mae
        ),
        "per_sample": samples,
        "limitations": [
            "Legacy headroom labels use a reverse-engineered MakerNote estimate.",
            "Gain above 3 stops is explicitly clipped and reported by the target audit.",
            "Pixel MAE does not establish perceptual HDR preference or correct HDR display output.",
            "This model predicts Apple-authored gain, not measured scene luminance.",
        ],
    }
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(
        json.dumps(
            {key: value for key, value in result.items() if key != "per_sample"},
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
