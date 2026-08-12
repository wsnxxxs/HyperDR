#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import nullcontext
import io
import json
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageCms

from hyperdr_ml.gain_io import write_gain_f32
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID, sha256_file
from hyperdr_ml.geometry import aligned_long_side_size
from hyperdr_ml.model import DirectGainMapNet


def srgb_eotf(encoded: np.ndarray) -> np.ndarray:
    return np.where(encoded <= 0.04045, encoded / 12.92, ((encoded + 0.055) / 1.055) ** 2.4)


def display_p3_profile(dataset_root: Path) -> ImageCms.ImageCmsProfile:
    path = dataset_root / "assets" / "display-p3.icc"
    if not path.exists():
        raise RuntimeError(
            f"Missing prebuilt Display P3 profile {path}; rebuild the training cache"
        )
    profile = ImageCms.ImageCmsProfile(io.BytesIO(path.read_bytes()))
    if ImageCms.getProfileDescription(profile).strip() != "Display P3":
        raise RuntimeError(f"Invalid Display P3 profile asset {path}")
    return profile


def autocast_context(device: torch.device):
    if device.type == "cuda":
        return torch.autocast("cuda", dtype=torch.bfloat16)
    return nullcontext()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument(
        "--input-report",
        type=Path,
        help="required descriptor for a linear Display-P3 float32 model input",
    )
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--gain-output", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--dataset-root", type=Path, default=Path.home() / "datasets/hyperdr-apple")
    parser.add_argument(
        "--allow-legacy-label-schema",
        action="store_true",
        help="allow inference from a frozen v1 checkpoint and emit a v1 sidecar",
    )
    parser.add_argument("--long-side", type=int, default=1024)
    parser.add_argument(
        "--device",
        choices=("auto", "cuda", "cpu"),
        default="auto",
        help="auto uses CUDA when available and otherwise falls back to CPU",
    )
    args = parser.parse_args()

    checkpoint = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    config = checkpoint["config"]
    expected_contract = "hyperdr.apple-gain-label/v1" if args.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise SystemExit(
            "checkpoint label contract is not permitted; pass --allow-legacy-label-schema "
            "only for an explicitly frozen v1 model"
        )
    manifest_path = args.dataset_root / "manifests" / "samples.jsonl"
    if "manifest_sha256" in checkpoint and checkpoint.get("manifest_sha256") != sha256_file(manifest_path):
        raise SystemExit("checkpoint manifest hash does not match --dataset-root")
    if not args.allow_legacy_label_schema:
        raise SystemExit(
            "the current model head emits normalized v1 gains; native ISO v2 inference "
            "is intentionally blocked until a v2-trained model exists"
        )
    if config.get("target_mode") != "fixed_3stops":
        raise SystemExit("Checkpoint does not predict fixed-scale absolute gain")

    model_input_descriptor = None
    if args.input_report is not None:
        model_input_descriptor = json.loads(args.input_report.read_text(encoding="utf-8"))
        if model_input_descriptor.get("schema") != "hyperdr.model-input/v1":
            raise SystemExit("unsupported --input-report schema")
        pixel_file = model_input_descriptor.get("pixel_file")
        geometry = model_input_descriptor.get("geometry")
        if not isinstance(pixel_file, dict) or not isinstance(geometry, dict):
            raise SystemExit("model input report is missing pixel or geometry metadata")
        if (pixel_file.get("format") != "raw_float32"
                or pixel_file.get("endianness") != "little"
                or pixel_file.get("layout") != "HWC"
                or pixel_file.get("color_space") != "linear Display P3"
                or pixel_file.get("channels") != 3):
            raise SystemExit("model input report does not describe linear Display-P3 HWC float32")
        source_width = int(pixel_file.get("width", 0))
        source_height = int(pixel_file.get("height", 0))
        expected_bytes = source_width * source_height * 3 * 4
        if (source_width <= 0 or source_height <= 0
                or int(pixel_file.get("byte_length", -1)) != expected_bytes
                or args.input.stat().st_size != expected_bytes
                or pixel_file.get("sha256") != sha256_file(args.input)):
            raise SystemExit("linear model input bytes do not match their report")
        if geometry.get("model_tensor_size") != [source_width, source_height]:
            raise SystemExit("model tensor dimensions disagree with the pixel descriptor")
        linear = np.fromfile(args.input, dtype="<f4").reshape(
            source_height, source_width, 3
        )
        if (not np.isfinite(linear).all() or np.min(linear) < 0.0
                or np.max(linear) > 1.0):
            raise SystemExit("linear model input contains values outside SDR [0,1]")
        input_profile_name = "linear Display P3 float32 (direct)"
    else:
        with Image.open(args.input) as source:
            source.load()
            source_rgb = source.convert("RGB")
            source_width, source_height = source_rgb.size
            embedded = source.info.get("icc_profile")
            p3 = display_p3_profile(args.dataset_root)
            if embedded:
                input_profile = ImageCms.ImageCmsProfile(io.BytesIO(embedded))
                input_profile_name = ImageCms.getProfileDescription(input_profile).strip()
            else:
                input_profile = ImageCms.createProfile("sRGB")
                input_profile_name = "assumed sRGB (no embedded ICC)"
            encoded_p3 = ImageCms.profileToProfile(
                source_rgb, input_profile, p3, outputMode="RGB"
            )

    if args.device == "cuda" and not torch.cuda.is_available():
        raise SystemExit("--device cuda was requested but CUDA is unavailable")
    device = torch.device(
        "cuda"
        if args.device == "cuda"
        or (args.device == "auto" and torch.cuda.is_available())
        else "cpu"
    )
    if model_input_descriptor is not None:
        model_width, model_height = source_width, source_height
        if model_width % 16 or model_height % 16:
            raise SystemExit("direct model input dimensions must be stride-16 aligned")
    else:
        model_width, model_height = aligned_long_side_size(
            (source_width, source_height), args.long_side
        )
        # Legacy raster compatibility. Native panel inference uses the direct
        # float path above and therefore performs no second resize or ICC trip.
        model_image = encoded_p3.resize(
            (model_width, model_height), Image.Resampling.LANCZOS
        )
        encoded = np.asarray(model_image, dtype=np.float32) / 255.0
        linear = srgb_eotf(encoded)
    tensor = (
        torch.from_numpy(np.transpose(linear, (2, 0, 1)))
        .unsqueeze(0)
        .to(device)
    )

    model = DirectGainMapNet(
        config["base_channels"], config.get("architecture", "baseline")
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    with torch.inference_mode(), autocast_context(device):
        encoded_gain = model(tensor).float().clamp(0.0, 1.0)[0, 0].cpu().numpy()
    if not np.isfinite(encoded_gain).all():
        raise RuntimeError("Model produced non-finite gain")

    gain_file = write_gain_f32(args.gain_output, encoded_gain)
    gain_stops = encoded_gain * 3.0
    checkpoint_hash = sha256_file(args.checkpoint)
    report = {
        "input": str(args.input),
        "checkpoint": str(args.checkpoint),
        "checkpoint_epoch": checkpoint["epoch"],
        "model_family": "DirectGainMapNet",
        "checkpoint_model_id": config.get(
            "model_id", "hyperdr.direct-gainmapnet/legacy-unversioned"
        ),
        "device": str(device),
        "source_size": [source_width, source_height],
        "input_profile": input_profile_name,
        "model_size": [model_width, model_height],
        "gain_grid_size": [int(encoded_gain.shape[1]), int(encoded_gain.shape[0])],
        "gain_file": gain_file,
        "metadata_gain_max_stops": 3.0,
        "label_contract_id": "hyperdr.apple-gain-label/v1",
        "legacy_schema": True,
        "predicted_gain_stops": {
            "min": float(gain_stops.min()),
            "mean": float(gain_stops.mean()),
            "p50": float(np.percentile(gain_stops, 50)),
            "p95": float(np.percentile(gain_stops, 95)),
            "max": float(gain_stops.max()),
        },
    }
    if model_input_descriptor is not None:
        gain_size = [int(encoded_gain.shape[1]), int(encoded_gain.shape[0])]
        report["model_binding"] = {
            "contract": "hyperdr.model-gain-binding/v1",
            "source": {
                "sha256": model_input_descriptor["source_sha256"],
                "highlight_recovery": model_input_descriptor["highlight_recovery"],
                "orientation": model_input_descriptor["orientation"],
                "sensor_size": model_input_descriptor["sensor_size"],
                "requested_crop": model_input_descriptor["requested_crop"],
                "delivered_crop": model_input_descriptor["delivered_crop"],
                "requested_crop_origin_sensor": model_input_descriptor[
                    "requested_crop_origin_sensor"
                ],
                "delivered_crop_origin_sensor": model_input_descriptor[
                    "delivered_crop_origin_sensor"
                ],
                "raw_half_size": model_input_descriptor["raw_half_size"],
            },
            "development_recipe": model_input_descriptor["development_recipe"],
            "geometry": {
                "developed_size": model_input_descriptor["geometry"]["developed_size"],
                "model_tensor_size": [model_width, model_height],
                "gain_grid_size": gain_size,
                "resize_convention": model_input_descriptor["geometry"]["resize_convention"],
            },
            "model": {
                "version": "%s@epoch-%s" % (
                    config.get("architecture", "baseline"), checkpoint["epoch"]
                ),
                "checkpoint_sha256": checkpoint_hash,
            },
        }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
