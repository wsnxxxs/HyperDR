#!/usr/bin/env python3
from __future__ import annotations

import argparse
from contextlib import nullcontext
import io
import json
import math
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageCms

from hyperdr_ml.gain_io import write_gain_f32, write_gain_f32_v2
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


_RATIONAL_DENOMINATOR = 1_000_000


def _rational_envelope(minimum: float, maximum: float) -> tuple[dict[str, int], dict[str, int]]:
    """Quantize outward so ISO metadata always contains every predicted stop."""
    minimum_numerator = math.floor(minimum * _RATIONAL_DENOMINATOR)
    maximum_numerator = math.ceil(maximum * _RATIONAL_DENOMINATOR)
    if maximum_numerator <= minimum_numerator:
        maximum_numerator = minimum_numerator + 1
    return (
        {"numerator": minimum_numerator, "denominator": _RATIONAL_DENOMINATOR},
        {"numerator": maximum_numerator, "denominator": _RATIONAL_DENOMINATOR},
    )


def _prediction_metadata(gain_stops: np.ndarray) -> tuple[dict[str, object], float]:
    minimum = float(np.min(gain_stops))
    maximum = float(np.max(gain_stops))
    if not math.isfinite(minimum) or not math.isfinite(maximum):
        raise RuntimeError("Model produced a non-finite signed-gain interval")
    if minimum < -64.0 or maximum > 64.0 or maximum < 0.0:
        raise RuntimeError("Model produced signed gains outside the ISO safety envelope")
    gain_min, gain_max = _rational_envelope(minimum, maximum)
    zero = {"numerator": 0, "denominator": _RATIONAL_DENOMINATOR}
    one = {
        "numerator": _RATIONAL_DENOMINATOR,
        "denominator": _RATIONAL_DENOMINATOR,
    }
    metadata = {
        "minimum_version": 0,
        "writer_version": 0,
        "flags": 64,
        "use_base_color_space": True,
        "backward_direction": False,
        "common_denominator": False,
        "base_headroom": zero,
        "alternate_headroom": gain_max,
        "gain_min": gain_min,
        "gain_max": gain_max,
        "gamma": one,
        "base_offset": zero,
        "alternate_offset": zero,
    }
    return metadata, gain_max["numerator"] / gain_max["denominator"]


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
    release_metadata: dict[str, object] = {}
    release_sidecar = args.checkpoint.with_suffix(".json")
    if release_sidecar.is_file():
        try:
            loaded_release_metadata = json.loads(
                release_sidecar.read_text(encoding="utf-8")
            )
            if isinstance(loaded_release_metadata, dict):
                release_metadata = loaded_release_metadata
        except (OSError, json.JSONDecodeError):
            pass
    checkpoint_model_id = str(
        config.get("model_id")
        or release_metadata.get("model_id")
        or (
            "hyperdr.direct-fixed-incumbent/v3"
            if not args.allow_legacy_label_schema
            else "hyperdr.direct-gainmapnet/legacy-unversioned"
        )
    )
    expected_contract = "hyperdr.apple-gain-label/v1" if args.allow_legacy_label_schema else LABEL_CONTRACT_ID
    actual_contract = checkpoint.get("label_contract_id", "hyperdr.apple-gain-label/v1")
    if actual_contract != expected_contract:
        raise SystemExit(
            "checkpoint label contract is not permitted; pass --allow-legacy-label-schema "
            "only for an explicitly frozen v1 model"
        )
    manifest_path = args.dataset_root / "manifests" / "samples.jsonl"
    # Release packages intentionally contain the color-profile asset but not
    # the private training corpus.  Verify the frozen manifest when a corpus is
    # supplied for audit/reproduction, while keeping ordinary inference
    # independent of training data.
    if ("manifest_sha256" in checkpoint and manifest_path.is_file()
            and checkpoint.get("manifest_sha256") != sha256_file(manifest_path)):
        raise SystemExit("checkpoint manifest hash does not match --dataset-root")
    legacy_schema = actual_contract == "hyperdr.apple-gain-label/v1"
    if legacy_schema:
        if config.get("target_mode") != "fixed_3stops":
            raise SystemExit("Legacy checkpoint does not predict fixed-scale absolute gain")
    elif config.get("model") != "direct" or config.get("target_mode") != "signed_stops":
        raise SystemExit("Native v2 inference requires a direct signed-stops checkpoint")

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
        config["base_channels"],
        config.get("architecture", "baseline"),
        "normalized_v1" if legacy_schema else "signed_stops_v2",
    ).to(device)
    model.load_state_dict(checkpoint["model"])
    model.eval()
    with torch.inference_mode(), autocast_context(device):
        prediction = model(tensor).float()[0, 0].cpu().numpy()
    if not np.isfinite(prediction).all():
        raise RuntimeError("Model produced non-finite gain")

    if legacy_schema:
        encoded_gain = np.clip(prediction, 0.0, 1.0)
        gain_stops = encoded_gain * 3.0
        gain_file = write_gain_f32(args.gain_output, encoded_gain)
        report = {
            "gain_grid_size": [int(encoded_gain.shape[1]), int(encoded_gain.shape[0])],
            "gain_file": gain_file,
            "metadata_gain_max_stops": 3.0,
            "label_contract_id": "hyperdr.apple-gain-label/v1",
            "legacy_schema": True,
        }
    else:
        gain_stops = np.asarray(prediction, dtype=np.float32)
        metadata, metadata_gain_max = _prediction_metadata(gain_stops)
        report = write_gain_f32_v2(
            args.gain_output,
            gain_stops,
            metadata=metadata,
            source_type="hyperdr_direct_model",
            confidence="model_prediction",
            formula_version="hyperdr.direct-signed-g/v3",
        )
        report.update({
            "metadata_gain_max_stops": metadata_gain_max,
            "legacy_schema": False,
        })
    checkpoint_hash = sha256_file(args.checkpoint)
    report.update({
        "input": str(args.input),
        "checkpoint": str(args.checkpoint),
        "checkpoint_epoch": checkpoint["epoch"],
        "model_family": "DirectGainMapNet",
        "checkpoint_model_id": checkpoint_model_id,
        "device": str(device),
        "source_size": [source_width, source_height],
        "input_profile": input_profile_name,
        "model_size": [model_width, model_height],
        "predicted_gain_stops": {
            "min": float(gain_stops.min()),
            "mean": float(gain_stops.mean()),
            "p50": float(np.percentile(gain_stops, 50)),
            "p95": float(np.percentile(gain_stops, 95)),
            "max": float(gain_stops.max()),
        },
    })
    if model_input_descriptor is not None:
        gain_size = [int(gain_stops.shape[1]), int(gain_stops.shape[0])]
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
                    checkpoint_model_id,
                    checkpoint["epoch"],
                ),
                "checkpoint_sha256": checkpoint_hash,
            },
        }
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
