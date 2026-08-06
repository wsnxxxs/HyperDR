#!/usr/bin/env python3
"""Validate the complete local Apple Gain Map dataset contract."""

from __future__ import annotations

import hashlib
import json
import math
import os
from collections import Counter
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from hyperdr_ml.geometry import MODEL_STRIDE

ROOT = Path.home() / "datasets/hyperdr-apple"


def main() -> None:
    rows = [json.loads(line) for line in (ROOT / "manifests" / "samples.jsonl").read_text().splitlines()]
    stats = {
        row["sample_id"]: row
        for row in (json.loads(line) for line in (ROOT / "manifests" / "canonical-stats.jsonl").read_text().splitlines())
    }
    errors: list[str] = []
    ids = [row["sample_id"] for row in rows]
    if len(set(ids)) != len(rows):
        errors.append(f"manifest count/uniqueness: {len(rows)}/{len(set(ids))}")

    gain_ids = {row["sample_id"] for row in rows if row["gain_map_present"]}
    if set(stats) != gain_ids:
        errors.append(f"gain/stat IDs mismatch: gain={len(gain_ids)} stats={len(stats)}")

    for index, row in enumerate(rows, 1):
        sample_id = row["sample_id"]
        source = ROOT / "originals" / f"{sample_id}.heic"
        proxy = ROOT / "extracted" / "sdr_1024" / f"{sample_id}.png"
        if not source.exists() or not proxy.exists():
            errors.append(f"missing source/proxy: {sample_id}")
            continue
        digest = hashlib.sha256()
        with source.open("rb") as handle:
            while chunk := handle.read(4 * 1024 * 1024):
                digest.update(chunk)
        if digest.hexdigest() != row["source_sha256"]:
            errors.append(f"source hash: {sample_id}")
        with Image.open(proxy) as image:
            if list(image.size) != row["proxy_size"]:
                errors.append(f"proxy dimensions: {sample_id}")
            if image.width % MODEL_STRIDE or image.height % MODEL_STRIDE:
                errors.append(f"proxy alignment: {sample_id}")

        gain_path = ROOT / "extracted" / "apple_gain_raw" / f"{sample_id}.png"
        canonical_path = ROOT / "extracted" / "canonical_log2_gain_f16" / f"{sample_id}.npy"
        preview_path = ROOT / "extracted" / "canonical_log2_gain_preview" / f"{sample_id}.png"
        if row["gain_map_present"]:
            if not all(path.exists() for path in (gain_path, canonical_path, preview_path)):
                errors.append(f"missing gain asset: {sample_id}")
                continue
            raw = cv2.imread(str(gain_path), cv2.IMREAD_UNCHANGED)
            canonical = np.load(canonical_path, allow_pickle=False)
            if raw is None or raw.dtype != np.uint8 or raw.ndim != 2:
                errors.append(f"raw gain format: {sample_id}")
            if canonical.dtype != np.float16 or canonical.shape != raw.shape:
                errors.append(f"canonical format: {sample_id}")
            if not np.isfinite(canonical).all():
                errors.append(f"canonical nonfinite: {sample_id}")
            maximum = float(row["canonical_max_log2_gain"])
            if float(canonical.min()) < -0.002 or float(canonical.max()) > maximum + 0.002:
                errors.append(f"canonical bounds: {sample_id}")
            linear_path = ROOT / "training" / "linear_p3_f16" / f"{sample_id}.npy"
            grid_path = (
                ROOT
                / "training"
                / "gain_grid_stride16_f16"
                / f"{sample_id}.npy"
            )
            if not linear_path.exists() or not grid_path.exists():
                errors.append(f"missing training cache: {sample_id}")
            else:
                linear = np.load(linear_path, allow_pickle=False)
                grid = np.load(grid_path, allow_pickle=False)
                expected_grid = (
                    1,
                    row["proxy_size"][1] // MODEL_STRIDE,
                    row["proxy_size"][0] // MODEL_STRIDE,
                )
                if linear.shape != (
                    3,
                    row["proxy_size"][1],
                    row["proxy_size"][0],
                ):
                    errors.append(f"linear cache shape: {sample_id}")
                if grid.shape != expected_grid:
                    errors.append(f"gain cache shape: {sample_id}")
                if not np.isfinite(linear).all() or not np.isfinite(grid).all():
                    errors.append(f"training cache nonfinite: {sample_id}")
        elif gain_path.exists() or canonical_path.exists() or preview_path.exists():
            errors.append(f"unexpected gain asset: {sample_id}")
        if index % 100 == 0:
            print(f"validated={index}/{len(rows)} errors={len(errors)}", flush=True)

    split_ids: dict[str, list[str]] = {}
    for name in ("train", "validation", "test"):
        split_ids[name] = json.loads((ROOT / "splits" / f"{name}.json").read_text())["sample_ids"]
    all_split = [item for values in split_ids.values() for item in values]
    if len(all_split) != len(set(all_split)) or set(all_split) != gain_ids:
        errors.append("split overlap or incompleteness")
    sample_split = {item: name for name, values in split_ids.items() for item in values}
    groups = json.loads((ROOT / "splits" / "groups.json").read_text())["groups"]
    group_members = []
    for group in groups:
        group_members.extend(group["members"])
        if any(sample_split[item] != group["split"] for item in group["members"]):
            errors.append(f"group crosses split: {group['group_id']}")
    if set(group_members) != gain_ids or len(group_members) != len(set(group_members)):
        errors.append("group coverage or overlap")

    manifest_private_keys = {"source_name", "capture_datetime", "capture_timezone_offset", "gps", "latitude", "longitude"}
    leaked_keys = sorted({key for row in rows for key in row if key.lower() in manifest_private_keys})
    if leaked_keys:
        errors.append(f"private keys in manifest: {leaked_keys}")

    summary = {
        "valid": not errors,
        "samples": len(rows),
        "gain_samples": len(gain_ids),
        "sky_mattes": sum(row["sky_matte_present"] for row in rows),
        "capture_groups": len(groups),
        "splits": {name: len(values) for name, values in split_ids.items()},
        "headroom_sources": dict(Counter(row["headroom_source"] for row in rows if row["gain_map_present"])),
        "per_image_eligible": sum(
            bool(row.get("per_image_eligible", False)) for row in rows
        ),
        "degenerate_gain_labels": sum(
            bool(row.get("degenerate_gain_label", False)) for row in rows
        ),
        "errors": errors,
    }
    path = ROOT / "reports" / "validation-summary.json"
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_text(json.dumps(summary, indent=2) + "\n")
    os.replace(temp, path)
    print(json.dumps(summary, indent=2))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
