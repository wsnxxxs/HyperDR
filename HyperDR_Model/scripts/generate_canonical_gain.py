#!/usr/bin/env python3
"""Convert Apple proprietary gain-map samples to canonical log2 gain grids."""

from __future__ import annotations

import json
import math
import os
from pathlib import Path

import cv2
import numpy as np

ROOT = Path.home() / "datasets/hyperdr-apple"
MANIFEST = ROOT / "manifests" / "samples.jsonl"
RAW_GAIN = ROOT / "extracted" / "apple_gain_raw"
LOG_GAIN = ROOT / "extracted" / "canonical_log2_gain_f16"
PREVIEW = ROOT / "extracted" / "canonical_log2_gain_preview"


def srgb_eotf(encoded: np.ndarray) -> np.ndarray:
    return np.where(encoded <= 0.04045, encoded / 12.92, ((encoded + 0.055) / 1.055) ** 2.4)


def atomic_save_npy(path: Path, array: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("wb") as handle:
        np.save(handle, array, allow_pickle=False)
    os.replace(temp, path)


def atomic_save_png(path: Path, image: np.ndarray) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp.png")
    if not cv2.imwrite(str(temp), image, [cv2.IMWRITE_PNG_COMPRESSION, 6]):
        raise RuntimeError(f"Failed to write {temp}")
    os.replace(temp, path)


def main() -> None:
    rows = [json.loads(line) for line in MANIFEST.read_text(encoding="utf-8").splitlines()]
    stats = []
    failures = []
    for index, row in enumerate(rows, 1):
        if not row["gain_map_present"]:
            continue
        sample_id = row["sample_id"]
        try:
            raw = cv2.imread(str(RAW_GAIN / f"{sample_id}.png"), cv2.IMREAD_UNCHANGED)
            if raw is None or raw.dtype != np.uint8 or raw.ndim != 2:
                raise ValueError(f"Expected uint8 mono gain map, got {None if raw is None else (raw.dtype, raw.shape)}")
            headroom = float(row["canonical_headroom"])
            if not math.isfinite(headroom) or not 1.0 <= headroom <= 32.0:
                raise ValueError(f"Invalid headroom {headroom}")
            max_log2_gain = math.log2(headroom)
            if bool(row.get("per_image_eligible", max_log2_gain > 0.0)) != (
                max_log2_gain > 0.0
            ):
                raise ValueError("Manifest per_image_eligible flag is inconsistent")
            encoded = raw.astype(np.float32) / 255.0
            gain_linear = 1.0 + (headroom - 1.0) * srgb_eotf(encoded)
            log_gain = np.log2(gain_linear).astype(np.float32)
            if not np.isfinite(log_gain).all() or log_gain.min() < -1e-6 or log_gain.max() > math.log2(headroom) + 2e-5:
                raise ValueError("Canonical gain is outside expected range")
            atomic_save_npy(LOG_GAIN / f"{sample_id}.npy", log_gain.astype(np.float16))
            if max_log2_gain > 0.0:
                preview = np.clip(
                    np.rint(log_gain / max_log2_gain * 65535.0), 0, 65535
                ).astype(np.uint16)
            else:
                preview = np.zeros_like(raw, dtype=np.uint16)
            atomic_save_png(PREVIEW / f"{sample_id}.png", preview)
            stats.append({
                "sample_id": sample_id,
                "height": int(log_gain.shape[0]),
                "width": int(log_gain.shape[1]),
                "min_log2_gain": float(log_gain.min()),
                "mean_log2_gain": float(log_gain.mean()),
                "p95_log2_gain": float(np.percentile(log_gain, 95)),
                "max_log2_gain": float(log_gain.max()),
                "per_image_eligible": max_log2_gain > 0.0,
            })
        except Exception as exc:
            failures.append({"sample_id": sample_id, "error": f"{type(exc).__name__}: {exc}"})
        if index % 100 == 0 or index == len(rows):
            print(f"scanned={index}/{len(rows)} generated={len(stats)} failures={len(failures)}", flush=True)

    if failures or len(stats) != sum(r["gain_map_present"] for r in rows):
        (ROOT / "reports" / "canonical-errors.json").write_text(json.dumps(failures, indent=2) + "\n")
        raise SystemExit(f"Canonical conversion incomplete: generated={len(stats)} failures={len(failures)}")

    path = ROOT / "manifests" / "canonical-stats.jsonl"
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        for item in stats:
            handle.write(json.dumps(item, separators=(",", ":")) + "\n")
    os.replace(temp, path)
    summary = {
        "samples": len(stats),
        "representation": "float16 log2(linear gain)",
        "formula": "log2(1 + (headroom - 1) * srgb_eotf(raw_gain_u8 / 255))",
        "preview": "uint16 normalized by per-sample log2(headroom); visualization only",
        "per_image_eligible": sum(item["per_image_eligible"] for item in stats),
        "degenerate_gain_labels": sum(not item["per_image_eligible"] for item in stats),
        "canonical_hdr_rgb_generated": False,
        "reason": "Training target is gain-only; SDR detail remains in immutable primary image",
    }
    (ROOT / "reports" / "canonical-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
