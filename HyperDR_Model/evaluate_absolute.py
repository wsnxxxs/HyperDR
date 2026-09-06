#!/usr/bin/env python3
from __future__ import annotations

import argparse
from collections import defaultdict
from contextlib import nullcontext
import json
from pathlib import Path

import torch
import torch.nn.functional as F
from torch.utils.data import DataLoader

from hyperdr_ml.data import (
    CV_FOLDS_NAME,
    AppleGainMapDataset,
    ShapeBucketBatchSampler,
    collate_gain_maps,
    grid_shapes,
)
from hyperdr_ml.loss import reconstruct_gain
from hyperdr_ml.model import DirectGainNet, GainMapNet, IntervalGainMapNet
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file
from hyperdr_ml.provenance import compare_digests
from hyperdr_ml.test_access import (
    CheckpointIdentityError,
    CheckpointTestAccess,
    claim_checkpoint_test_access,
    validate_checkpoint_config_hash,
    validate_checkpoint_development_split_hashes,
)

MODEL_CLASSES = {
    "map_only": GainMapNet,
    "interval": IntervalGainMapNet,
    "direct": DirectGainNet,
}


def validate_claimed_test_membership(
    dataset: AppleGainMapDataset,
    test_access: CheckpointTestAccess,
) -> None:
    """Bind the dataset actually scored to the membership validated at claim time."""
    actual = tuple(str(row["sample_id"]) for row in dataset.rows)
    if actual != test_access.validated_test_ids:
        raise CheckpointIdentityError(
            "test dataset membership/order changed after the one-shot claim; "
            "refusing to score bytes not validated by the consumed ledger"
        )


def predict_stops(
    model: torch.nn.Module,
    model_kind: str,
    batch: dict[str, torch.Tensor],
    device: torch.device,
) -> torch.Tensor:
    """Absolute log2 gain in stops, however this model happens to produce it."""
    sdr = batch["sdr"].to(device, non_blocking=device.type == "cuda")
    if model_kind == "interval":
        output = model(sdr, batch["mask"].to(device, non_blocking=device.type == "cuda"))
        return reconstruct_gain(
            output["map"].float().cpu(),
            output["gain_min"].float().cpu(),
            output["gain_max"].float().cpu(),
        )
    if model_kind == "direct":
        return model(sdr).float().cpu()
    return to_stops(model(sdr).float().cpu(), batch)


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


def to_stops(normalized: torch.Tensor, batch: dict[str, torch.Tensor]) -> torch.Tensor:
    """Undo the dataset's normalization, using the scale it declared.

    The affine map is per image under iso_interval, so it is read from the
    batch rather than assumed to be the fixed 3-stop constant.
    """
    scale = batch["stops_per_unit"].reshape(-1, 1, 1, 1).to(normalized.dtype)
    offset = batch["stops_offset"].reshape(-1, 1, 1, 1).to(normalized.dtype)
    return normalized * scale + offset


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--checkpoint", required=True)
    parser.add_argument("--output", required=True)
    # H3: no default.  The frozen test split is one-shot, and a default of
    # `test` means the protection depends on everyone remembering to pass the
    # flag -- the one case where forgetting is unrecoverable, because a test
    # split that has been looked at cannot be un-looked at.
    parser.add_argument(
        "--split",
        choices=("validation", "selection", "holdout", "test"),
        required=True,
        help=(
            "selection scores a production checkpoint's checkpoint-selection "
            "fold; holdout scores a research checkpoint's judgment fold, which the run "
            "excluded from training and from every selection it made; test is "
            "the frozen one-shot split and needs --one-shot-test-evaluation"
        ),
    )
    parser.add_argument(
        "--one-shot-test-evaluation",
        action="store_true",
        help=(
            "required with --split test. Scoring the frozen test split is a "
            "one-time act: after it, the split can no longer inform any choice "
            "about this model family (H3)"
        ),
    )
    parser.add_argument(
        "--protocol-id",
        help=(
            "research protocol consuming the one-shot test split; required only "
            "with --split test and recorded in the dataset-wide ledger"
        ),
    )
    parser.add_argument("--device", choices=("auto", "cuda", "cpu"), default="auto")
    parser.add_argument(
        "--input-cache-dir",
        help=(
            "override the checkpoint's SDR cache for deployment-matched stress "
            "evaluation; sample ids and canonical targets remain unchanged"
        ),
    )
    parser.add_argument(
        "--target-cache-dir",
        help="paired signed-stop targets rebased to --input-cache-dir",
    )
    parser.add_argument("--baseline-report", help="optional v3 report for relative improvement")
    parser.add_argument("--max-capture-group-mae", type=float)
    parser.add_argument("--max-highlight-mae", type=float)
    parser.add_argument("--max-hdr-log-contrast-span-mae", type=float)
    parser.add_argument(
        "--require-contrast-span-improvement",
        type=float,
        help="minimum relative reduction versus baseline HDR log-luminance contrast-span MAE",
    )
    parser.add_argument("--allow-legacy-label-schema", action="store_true")
    args = parser.parse_args()
    if args.split == "test" and not args.one_shot_test_evaluation:
        raise SystemExit(
            "--split test scores the hash-locked one-shot split; pass "
            "--one-shot-test-evaluation to state that this is that one shot. "
            "Use --split holdout to score a judgment fold, or --split validation."
        )
    if args.split != "test" and args.one_shot_test_evaluation:
        raise SystemExit(
            "--one-shot-test-evaluation applies only to --split test; a run that "
            "declares the one shot but scores another split misfiles its own record"
        )
    if args.split == "test" and not args.protocol_id:
        raise SystemExit(
            "--split test requires --protocol-id so the dataset-wide consumption "
            "ledger records which frozen research protocol used the one shot"
        )
    if args.split != "test" and args.protocol_id:
        raise SystemExit("--protocol-id applies only to --split test")
    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    try:
        config = validate_checkpoint_config_hash(checkpoint)
    except CheckpointIdentityError as exc:
        raise SystemExit(str(exc)) from exc
    evaluation_input_cache = args.input_cache_dir or config.get("input_cache_dir")
    evaluation_target_cache = args.target_cache_dir or config.get("target_cache_dir")
    if (evaluation_input_cache is None) != (evaluation_target_cache is None):
        raise SystemExit(
            "deployment evaluation requires --input-cache-dir and "
            "--target-cache-dir together; refusing an SDR/target mismatch"
        )
    expected_contract = "hyperdr.apple-gain-label/v1" if args.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise SystemExit("checkpoint label contract is not permitted by the schema gate")
    target_mode = config.get("target_mode")
    model_kind = config.get("model", "map_only")
    if target_mode not in ("fixed_3stops", "iso_interval", "signed_stops"):
        # per_image normalizes each image by its own maximum, so its predictions
        # carry no common absolute scale for these buckets.
        raise SystemExit(
            f"This evaluator requires an absolute-stops target mode, got {target_mode!r}"
        )
    if model_kind not in MODEL_CLASSES:
        raise SystemExit(f"unknown model kind {model_kind!r} in the checkpoint config")
    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda was requested but CUDA is unavailable")
    device = torch.device(
        "cuda"
        if args.device == "cuda"
        or (args.device == "auto" and torch.cuda.is_available())
        else "cpu"
    )

    root = Path(config["dataset_root"])
    # H6: presence-required.  "Compare it if it is there" is not a check; it is
    # a check that exempts precisely the checkpoints nothing else vouches for.
    if "manifest_sha256" not in checkpoint:
        raise SystemExit(
            "checkpoint carries no manifest_sha256, so it cannot be shown to "
            "have been trained on this dataset"
        )
    if checkpoint["manifest_sha256"] != sha256_file(root / "manifests" / "samples.jsonl"):
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
    fold = config.get("fold")
    production_selection_fold = config.get("production_selection_fold")
    try:
        validate_checkpoint_development_split_hashes(
            root,
            checkpoint,
            fold=int(fold) if fold is not None else None,
        )
    except CheckpointIdentityError as exc:
        raise SystemExit(str(exc)) from exc
    if args.split == "holdout":
        if fold is None:
            raise SystemExit("--split holdout needs a checkpoint trained with --fold")
        folds_path = root / "splits" / CV_FOLDS_NAME
        if "cv_folds_sha256" not in checkpoint:
            raise SystemExit(
                "checkpoint carries no cv_folds_sha256; without it the fold "
                "index does not identify a fixed set of samples"
            )
        if checkpoint["cv_folds_sha256"] != sha256_file(folds_path):
            raise SystemExit(
                "the fold partition changed since training; this fold index no "
                "longer names the same samples"
            )
    if args.split == "selection":
        if production_selection_fold is None:
            raise SystemExit(
                "--split selection needs a production checkpoint trained with "
                "--production-selection-fold"
            )
        folds_path = root / "splits" / CV_FOLDS_NAME
        if checkpoint.get("cv_folds_sha256") != sha256_file(folds_path):
            raise SystemExit(
                "the fold partition changed since production training; the "
                "checkpoint-selection fold no longer names the same samples"
            )
    test_access: CheckpointTestAccess | None = None
    if args.split == "test":
        try:
            test_access = claim_checkpoint_test_access(
                root,
                checkpoint,
                args.checkpoint,
                entrypoint="evaluate_absolute.py",
                protocol_id=args.protocol_id,
            )
        except (CheckpointIdentityError, OSError, RuntimeError, ValueError) as exc:
            raise SystemExit(f"test split access refused: {exc}") from exc
    dataset = AppleGainMapDataset(
        root, "holdout" if args.split == "selection" else args.split,
        config["label_subset"], False, target_mode,
        allow_legacy_label_schema=args.allow_legacy_label_schema,
        fold=(
            fold
            if args.split == "holdout"
            else production_selection_fold if args.split == "selection" else None
        ),
        # A command-line boolean is not a capability. This becomes true only
        # after the shared O_EXCL ledger claim and registered-hash validation.
        one_shot_test_evaluation=(
            test_access.data_capability if test_access is not None else False
        ),
        input_cache_dir=evaluation_input_cache,
        target_cache_dir=evaluation_target_cache,
    )
    if test_access is not None:
        try:
            validate_claimed_test_membership(dataset, test_access)
        except CheckpointIdentityError as exc:
            raise SystemExit(f"test split access refused after claim: {exc}") from exc
    # Evaluate with the same batching discipline the checkpoint was trained
    # under.  It is not cosmetic: with mixed shapes, collate pads and every
    # GroupNorm sees the padding, so a per-image metric would depend on batch
    # composition and the paired bootstrap would be resampling noise it made up.
    batch_by_shape = bool(config.get("batch_by_shape", False))

    def make_loader(source: AppleGainMapDataset) -> DataLoader:
        if batch_by_shape:
            return DataLoader(
                source,
                batch_sampler=ShapeBucketBatchSampler(
                    grid_shapes(source), batch_size=8, shuffle=False
                ),
                num_workers=4,
                collate_fn=collate_gain_maps,
            )
        return DataLoader(
            source, batch_size=8, num_workers=4, collate_fn=collate_gain_maps
        )

    loader = make_loader(dataset)
    # The constant baseline must come from the data this checkpoint actually
    # trained on, which under a fold run excludes both the judgment fold and the
    # selection fold. Taking it from the whole pool would let the judgment fold
    # inform the baseline it is being compared against.
    train_dataset = AppleGainMapDataset(
        root, "train", config["label_subset"], False, target_mode,
        allow_legacy_label_schema=args.allow_legacy_label_schema,
        exclude_folds=(
            (fold, config["selection_fold"])
            if fold is not None
            else (production_selection_fold,)
            if production_selection_fold is not None
            else ()
        ),
        input_cache_dir=evaluation_input_cache,
        target_cache_dir=evaluation_target_cache,
    )
    # H1: the training set this evaluation just reconstructed must be the one
    # the checkpoint recorded, down to the source bytes of every sample. This is
    # the point where provenance stops being a data-tier record and becomes a
    # condition on the score: a checkpoint that cannot prove which corpus it was
    # fit to does not get evaluated.
    compare_digests(
        checkpoint.get("provenance_digest"),
        train_dataset.provenance_digest,
        what="the checkpoint under evaluation",
    )
    train_loader = make_loader(train_dataset)
    train_sum = 0.0
    train_count = 0.0
    for batch in train_loader:
        train_sum += float((to_stops(batch["target"], batch) * batch["mask"]).sum())
        train_count += float(batch["mask"].sum())
    train_mean_stops = train_sum / train_count

    model = MODEL_CLASSES[model_kind](
        config["base_channels"], config.get("architecture", "baseline")
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()

    buckets = defaultdict(accumulator)
    samples = []
    highlight_sum_abs = 0.0
    highlight_images = 0
    contrast_span_abs_sum = 0.0
    contrast_span_samples = 0
    constant_sum_abs = 0.0
    constant_count = 0
    with torch.inference_mode():
        for batch in loader:
            with autocast_context(device):
                prediction = predict_stops(model, model_kind, batch, device)
            target = to_stops(batch["target"], batch)
            mask = batch["mask"].bool()
            sdr = batch["sdr"].float()
            luminance = (
                0.22897456 * sdr[:, 0:1]
                + 0.69173852 * sdr[:, 1:2]
                + 0.07928691 * sdr[:, 2:3]
            )
            log_luminance = torch.log2(
                F.adaptive_avg_pool2d(luminance, target.shape[-2:]).clamp_min(1e-6)
            )
            constant_error = (target[mask] - train_mean_stops).abs()
            constant_sum_abs += float(constant_error.sum())
            constant_count += constant_error.numel()

            for index, sample_id in enumerate(batch["sample_id"]):
                valid = mask[index]
                predicted = prediction[index][valid]
                expected = target[index][valid]
                error = (predicted - expected).abs()
                highlight = expected >= 1.0
                if bool(highlight.any()):
                    # Match training/release aggregation: compute a highlight
                    # mean within each valid image, then weight images equally.
                    highlight_sum_abs += float(error[highlight].mean())
                    highlight_images += 1
                base_log = log_luminance[index][valid]
                truth_hdr_log = base_log + expected
                predicted_hdr_log = base_log + predicted
                truth_span = torch.quantile(truth_hdr_log, 0.95) - torch.quantile(
                    truth_hdr_log, 0.05
                )
                predicted_span = torch.quantile(
                    predicted_hdr_log, 0.95
                ) - torch.quantile(predicted_hdr_log, 0.05)
                span_error = float((predicted_span - truth_span).abs())
                contrast_span_abs_sum += span_error
                contrast_span_samples += 1
                row = manifest[sample_id]
                source = (
                    "xmp"
                    if row["headroom_source"] == "xmp_hdr_gain_map_headroom"
                    else "legacy"
                )
                sample = {
                    "sample_id": sample_id,
                    # Carried on the batch, not re-joined from a manifest here:
                    # a report that resolves its own provenance at write time
                    # can disagree with the data the model actually saw.
                    "domain": batch["domain"][index],
                    "writer_profile": batch["writer_profile"][index],
                    "source_sha256": batch["source_sha256"][index],
                    "headroom_source": source,
                    "mae_stops": float(error.mean()),
                    "target_mean_stops": float(expected.mean()),
                    "prediction_mean_stops": float(predicted.mean()),
                    "target_p95_stops": float(torch.quantile(expected, 0.95)),
                    "prediction_p95_stops": float(
                        torch.quantile(predicted, 0.95)
                    ),
                    "absolute_highlight_mae_stops": (
                        float(error[highlight].mean()) if bool(highlight.any()) else None
                    ),
                    "target_hdr_log_luminance_p95_p05_span_stops": float(truth_span),
                    "prediction_hdr_log_luminance_p95_p05_span_stops": float(predicted_span),
                    "hdr_log_luminance_contrast_span_absolute_error_stops": span_error,
                }
                samples.append(sample)
                # Sliced by provenance domain as well as headroom source: the
                # two Apple sub-domains are near mirror images at the endpoints,
                # so a single pooled number describes neither of them.
                for name in ("all", source, f"domain:{sample['domain']}"):
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
    group_record = json.loads((root / "splits" / "groups.json").read_text())["groups"]
    group_of = {
        str(sample_id): str(group["group_id"])
        for group in group_record
        for sample_id in group["members"]
    }
    group_errors: dict[str, list[float]] = defaultdict(list)
    for sample in samples:
        group_errors[group_of[str(sample["sample_id"])]].append(float(sample["mae_stops"]))
    capture_group_mae = sum(
        sum(values) / len(values) for values in group_errors.values()
    ) / len(group_errors)
    quality_metrics = {
        "capture_group_gain_mae_stops": capture_group_mae,
        "absolute_highlight_mae_stops": (
            highlight_sum_abs / highlight_images if highlight_images else None
        ),
        "per_image_hdr_log_luminance_contrast_span_mae_stops": (
            contrast_span_abs_sum / contrast_span_samples
            if contrast_span_samples else None
        ),
        "capture_groups": len(group_errors),
        "highlight_images": highlight_images,
    }
    result = {
        "checkpoint_epoch": checkpoint["epoch"],
        "split": args.split,
        "samples": len(dataset),
        "device": str(device),
        "label_contract_id": actual_contract,
        "target_mode": target_mode,
        "model": model_kind,
        "batch_by_shape": batch_by_shape,
        "input_cache_dir": str(evaluation_input_cache) if evaluation_input_cache else None,
        "target_cache_dir": str(evaluation_target_cache) if evaluation_target_cache else None,
        "deployment_matched_input": bool(evaluation_input_cache),
        "quality_metrics": quality_metrics,
        "quality_metric_definitions": {
            "capture_group_gain_mae_stops": (
                "mean pixel MAE within each image, then mean within capture group, "
                "then equal-weight mean across capture groups"
            ),
            "absolute_highlight_mae_stops": (
                "target >= 1 stop; mean over highlight pixels within each valid "
                "image, then equal-weight mean across images, matching training/release"
            ),
            "per_image_hdr_log_luminance_contrast_span_mae_stops": (
                "absolute error in p95-p05 of low-resolution log2 HDR luminance, "
                "then equal-weight mean across images"
            ),
        },
        "provenance": {
            "scored_split": dataset.provenance_digest,
            "checkpoint_train_split": checkpoint["provenance_digest"],
        },
        "target": (
            "absolute log2 gain in fixed 0-3 stop range"
            if target_mode == "fixed_3stops"
            else "raw signed canonical log2 gain in stops"
            if target_mode == "signed_stops"
            else "absolute log2 gain, recovered from each file's declared ISO interval"
        ),
        "buckets": bucket_report,
        "train_mean_constant_baseline_stops": train_mean_stops,
        "train_mean_constant_pixel_mae_stops": constant_mae,
        "relative_improvement_vs_constant": (
            (constant_mae - overall_mae) / constant_mae
        ),
        "per_sample": samples,
        "limitations": [
            "Legacy headroom labels use a reverse-engineered MakerNote estimate.",
            (
                "Gain above 3 stops is explicitly clipped and reported by the target audit."
                if target_mode == "fixed_3stops"
                else (
                    "The interval endpoints are predicted; this is an end-to-end "
                    "SDR-only reconstruction."
                    if model_kind in ("interval", "direct")
                    else "Endpoints are taken from the ground-truth label; this model "
                    "predicts only the spatial map, so these numbers do not describe "
                    "an end-to-end SDR-only prediction."
                )
            ),
            "Pixel MAE does not establish perceptual HDR preference or correct HDR display output.",
            "This model predicts Apple-authored gain, not measured scene luminance.",
        ],
    }
    if evaluation_input_cache is not None:
        cache_manifest = Path(evaluation_input_cache) / "deployment-cache.jsonl"
        result["deployment_cache_manifest"] = {
            "file": str(cache_manifest),
            "sha256": sha256_file(cache_manifest),
            "rows": sum(1 for line in cache_manifest.read_text().splitlines() if line.strip()),
            "paired_target_contract": "signed_log2_stops_rebased_to_deployment_sdr/v1",
        }
    if args.split == "selection":
        result["selection_role"] = (
            "checkpoint/epoch selection only; not a fresh blind-test estimate"
        )
    if args.baseline_report:
        baseline = json.loads(Path(args.baseline_report).read_text())
        baseline_metrics = baseline.get("quality_metrics")
        if not isinstance(baseline_metrics, dict):
            raise SystemExit("--baseline-report has no quality_metrics mapping")
        relative = {}
        for name in (
            "capture_group_gain_mae_stops",
            "absolute_highlight_mae_stops",
            "per_image_hdr_log_luminance_contrast_span_mae_stops",
        ):
            old, new = baseline_metrics.get(name), quality_metrics.get(name)
            relative[name] = (
                (float(old) - float(new)) / float(old)
                if old is not None and new is not None and float(old) != 0.0
                else None
            )
        result["relative_improvement_vs_baseline"] = relative
    gates = []
    for name, limit in (
        ("capture_group_gain_mae_stops", args.max_capture_group_mae),
        ("absolute_highlight_mae_stops", args.max_highlight_mae),
        (
            "per_image_hdr_log_luminance_contrast_span_mae_stops",
            args.max_hdr_log_contrast_span_mae,
        ),
    ):
        if limit is not None:
            value = quality_metrics[name]
            gates.append({"metric": name, "operator": "<=", "limit": limit,
                          "value": value, "passed": value is not None and value <= limit})
    if args.require_contrast_span_improvement is not None:
        relative = result.get("relative_improvement_vs_baseline", {}).get(
            "per_image_hdr_log_luminance_contrast_span_mae_stops"
        )
        gates.append({
            "metric": "hdr_log_luminance_contrast_span_relative_improvement",
            "operator": ">=", "limit": args.require_contrast_span_improvement,
            "value": relative,
            "passed": relative is not None and relative >= args.require_contrast_span_improvement,
        })
    if gates:
        result["selection_gates"] = {
            "passed": all(bool(gate["passed"]) for gate in gates),
            "checks": gates,
        }
    if test_access is not None:
        result["one_shot_test_access"] = {
            "ledger_path": str(test_access.claim.ledger_path),
            "protocol_id": test_access.claim.protocol_id,
            "checkpoint_sha256": test_access.checkpoint_sha256,
            "registered_test_split_sha256": (
                test_access.registered_test_split_sha256
            ),
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
    if gates and not result["selection_gates"]["passed"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
