#!/usr/bin/env python3
"""Build GPU-friendly linear-P3 SDR tensors and stride-16 gain targets."""

from __future__ import annotations

import argparse
import io
import json
import os
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageCms

from hyperdr_ml.geometry import MODEL_STRIDE, target_grid_size


def srgb_eotf(encoded: np.ndarray) -> np.ndarray:
    return np.where(encoded <= 0.04045, encoded / 12.92, ((encoded + 0.055) / 1.055) ** 2.4)


def atomic_npy(path: Path, array: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("wb") as handle:
        np.save(handle, array, allow_pickle=False)
    os.replace(temp, path)


def atomic_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_bytes(data)
    os.replace(temp, path)


def display_p3_profile(
    root: Path, rows: list[dict[str, object]], sdr_dir: Path
) -> ImageCms.ImageCmsProfile:
    asset = root / "assets" / "display-p3.icc"
    if asset.exists():
        profile = ImageCms.ImageCmsProfile(io.BytesIO(asset.read_bytes()))
        if ImageCms.getProfileDescription(profile).strip() != "Display P3":
            raise ValueError(f"Invalid Display P3 asset: {asset}")
        return profile
    for row in rows:
        path = sdr_dir / f"{row['sample_id']}.png"
        with Image.open(path) as image:
            data = image.info.get("icc_profile")
        if data:
            profile = ImageCms.ImageCmsProfile(io.BytesIO(data))
            if ImageCms.getProfileDescription(profile).strip() == "Display P3":
                atomic_bytes(asset, data)
                return ImageCms.ImageCmsProfile(io.BytesIO(data))
    raise ValueError("No Display P3 ICC profile is available to prebuild the asset")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root", type=Path, default=Path.home() / "datasets/hyperdr-apple"
    )
    parser.add_argument("--long-side", type=int, default=1024)
    args = parser.parse_args()
    root: Path = args.root
    manifest = root / "manifests" / "samples.jsonl"
    sdr_dir = root / "extracted" / f"sdr_{args.long_side}"
    gain_dir = root / "extracted" / "canonical_log2_gain_f16"
    linear_dir = root / "training" / "linear_p3_f16"
    grid_dir = root / "training" / "gain_grid_stride16_f16"

    rows = [json.loads(line) for line in manifest.read_text().splitlines()]
    rows = [row for row in rows if row["gain_map_present"]]
    p3_profile = display_p3_profile(root, rows, sdr_dir)
    failures = []
    index_rows = []
    for index, row in enumerate(rows, 1):
        sample_id = row["sample_id"]
        try:
            with Image.open(sdr_dir / f"{sample_id}.png") as image:
                rgb = image.convert("RGB")
                profile_data = image.info.get("icc_profile")
                profile_name = None
                if profile_data:
                    profile_name = ImageCms.getProfileDescription(ImageCms.ImageCmsProfile(io.BytesIO(profile_data))).strip()
                if profile_name == "Display P3":
                    encoded_p3 = np.asarray(rgb, dtype=np.float32) / 255.0
                    color_source = "embedded_display_p3"
                elif profile_data is None and row["color_profile"] == "nclx":
                    srgb_profile = ImageCms.createProfile("sRGB")
                    converted = ImageCms.profileToProfile(
                        rgb, srgb_profile, p3_profile, outputMode="RGB"
                    )
                    encoded_p3 = np.asarray(converted, dtype=np.float32) / 255.0
                    color_source = "nclx_bt709_to_display_p3"
                else:
                    raise ValueError(f"Unsupported color profile {profile_name!r}/{row['color_profile']}")

            linear = srgb_eotf(encoded_p3).astype(np.float32)
            chw = np.transpose(linear, (2, 0, 1)).astype(np.float16)
            proxy_width, proxy_height = rgb.size
            if [proxy_width, proxy_height] != row["proxy_size"]:
                raise ValueError(
                    f"Proxy size {rgb.size} disagrees with manifest {row['proxy_size']}"
                )
            target_width, target_height = target_grid_size(rgb.size)
            if chw.shape[-2:] != (proxy_height, proxy_width):
                raise ValueError("CHW conversion changed proxy dimensions")
            if not np.isfinite(chw).all():
                raise ValueError("Non-finite linear-P3 proxy")
            atomic_npy(linear_dir / f"{sample_id}.npy", chw)

            gain = np.load(
                gain_dir / f"{sample_id}.npy", allow_pickle=False
            ).astype(np.float32)
            if not np.isfinite(gain).all():
                raise ValueError("Non-finite canonical gain")
            # INTER_AREA computes an anti-aliased spatial average suitable for
            # a low-frequency target grid. Deployment reconstruction must use
            # the same grid convention during model integration.
            grid = cv2.resize(gain, (target_width, target_height), interpolation=cv2.INTER_AREA)
            grid = grid.astype(np.float16)[None, ...]
            expected_shape = (
                1,
                proxy_height // MODEL_STRIDE,
                proxy_width // MODEL_STRIDE,
            )
            if grid.shape != expected_shape:
                raise ValueError(
                    f"Target shape {grid.shape} does not match proxy/16 {expected_shape}"
                )
            atomic_npy(grid_dir / f"{sample_id}.npy", grid)
            index_rows.append({
                "sample_id": sample_id,
                "linear_p3_shape": list(chw.shape),
                "gain_grid_shape": [1, target_height, target_width],
                "color_source": color_source,
            })
        except Exception as exc:
            failures.append({"sample_id": sample_id, "error": f"{type(exc).__name__}: {exc}"})
        if index % 100 == 0 or index == len(rows):
            print(f"processed={index}/{len(rows)} generated={len(index_rows)} failures={len(failures)}", flush=True)

    if failures or len(index_rows) != len(rows):
        (root / "reports" / "training-cache-errors.json").write_text(json.dumps(failures, indent=2) + "\n")
        raise SystemExit(f"Training cache incomplete: {len(index_rows)}/{len(rows)}")

    path = root / "manifests" / "training-cache.jsonl"
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w") as handle:
        for row in index_rows:
            handle.write(json.dumps(row, separators=(",", ":")) + "\n")
    os.replace(temp, path)
    summary = {
        "samples": len(index_rows),
        "sdr_representation": "CHW float16 linear Display-P3, relative SDR white=1",
        "gain_representation": "1HW float16 log2 linear gain, stride-16 relative to SDR proxy",
        "gain_downsampling": "OpenCV INTER_AREA from native canonical gain",
        "proxy_alignment": MODEL_STRIDE,
        "shape_contract": "gain_grid_shape == (1, proxy_height/16, proxy_width/16)",
        "display_p3_profile_asset": "assets/display-p3.icc",
        "input_detail_policy": "1024 proxy is used only for semantic gain prediction; original HEIC remains the SDR detail source",
    }
    (root / "reports" / "training-cache-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
