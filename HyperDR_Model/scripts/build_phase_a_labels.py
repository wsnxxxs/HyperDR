#!/usr/bin/env python3
"""Build the frozen Phase A v2 canonical label corpus.

This command never overwrites the v1 float16 labels.  It reads the immutable
Apple source/manifest and writes a separate signed-float32 tree plus a corpus
lock which records every input and output hash.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path

import cv2
import numpy as np

from hyperdr_ml.gain_io import write_descriptor, write_gain_f32_v2
from hyperdr_ml.phase_a_labels import (
    FORMULA_VERSION,
    LABEL_CONTRACT_ID,
    IsoGainMapMetadata,
    PhaseALabelError,
    Rational,
    decode_iso_gain_code,
    decode_legacy_gain_code,
    extract_tmap_payload,
    parse_tmap_payload,
    parse_xmp_headroom,
    canonical_formula,
    sha256_file,
)


def _manifest_hash(path: Path) -> str:
    return sha256_file(path)


def _read_gain(path: Path) -> np.ndarray:
    raw = cv2.imread(str(path), cv2.IMREAD_UNCHANGED)
    if raw is None or raw.dtype != np.uint8 or raw.ndim != 2:
        raise PhaseALabelError(f"expected uint8 monochrome gain map, got {path}")
    return raw


def _legacy_metadata(headroom: float) -> IsoGainMapMetadata:
    if not math.isfinite(headroom) or headroom < 1.0 or headroom > 32.0:
        raise PhaseALabelError(f"invalid legacy headroom {headroom!r}")
    stops = math.log2(headroom)
    q = lambda value: Rational(int(round(value * 1_000_000)), 1_000_000)
    return IsoGainMapMetadata(
        minimum_version=0,
        writer_version=0,
        flags=0x40,
        use_base_color_space=True,
        backward_direction=False,
        common_denominator=False,
        base_headroom=q(0.0),
        alternate_headroom=q(stops),
        gain_min=q(0.0),
        gain_max=q(stops),
        gamma=q(1.0),
        base_offset=q(0.0),
        alternate_offset=q(0.0),
    )


def _atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def build(root: Path, *, require_counts: bool = False) -> dict[str, object]:
    manifest_path = root / "manifests" / "samples.jsonl"
    rows = [json.loads(line) for line in manifest_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    raw_dir = root / "extracted" / "apple_gain_raw"
    source_dir = root / "originals"
    output_dir = root / "extracted" / "canonical_log2_gain_f32_v2"
    sidecar_dir = root / "manifests" / "phase_a_labels_v2"
    lock_rows: list[dict[str, object]] = []
    failures: list[dict[str, str]] = []

    for index, row in enumerate(rows, 1):
        if not row.get("gain_map_present", False):
            continue
        sample_id = str(row["sample_id"])
        try:
            raw_path = raw_dir / f"{sample_id}.png"
            raw = _read_gain(raw_path)
            source_bytes = (source_dir / f"{sample_id}.heic").read_bytes()
            version = int(row.get("gain_map_version") or 0)
            if version == 131072:
                payload = extract_tmap_payload(source_bytes)
                metadata = parse_tmap_payload(payload)
                xmp_headroom = parse_xmp_headroom(source_bytes)
                if xmp_headroom is None:
                    raise PhaseALabelError("native ISO sample has no XMP headroom")
                expected = 2.0 ** metadata.alternate_headroom.value
                if abs(expected - xmp_headroom) > 2.0e-5 * max(1.0, expected):
                    raise PhaseALabelError(
                        f"XMP/tmap headroom conflict ({xmp_headroom} vs {expected})"
                    )
                if abs(metadata.gain_max.value - metadata.alternate_headroom.value) > 1.0e-6:
                    raise PhaseALabelError("native ISO gain_max must equal alternate headroom")
                canonical = decode_iso_gain_code(raw, metadata).astype(np.float32)
                source_type = "iso_21496_1_tmap"
                confidence = "high"
            elif version == 65536:
                headroom = row.get("canonical_headroom")
                if headroom is None:
                    raise PhaseALabelError("legacy sample has no resolved MakerNote headroom")
                metadata = _legacy_metadata(float(headroom))
                canonical = decode_legacy_gain_code(raw, float(headroom)).astype(np.float32)
                source_type = "legacy_apple"
                confidence = "low"
                payload = None
            else:
                raise PhaseALabelError(f"unknown Apple gain-map version {version}")
            if not np.isfinite(canonical).all():
                raise PhaseALabelError("canonical gain contains non-finite values")
            output_path = output_dir / f"{sample_id}.f32"
            descriptor = write_gain_f32_v2(
                output_path,
                canonical,
                metadata=metadata.as_dict(),
                source_type=source_type,
                confidence=confidence,
                formula_version=FORMULA_VERSION,
            )
            descriptor.update(
                {
                    "sample_id": sample_id,
                    "source_sha256": sha256_file(source_dir / f"{sample_id}.heic"),
                    "source_gain_sha256": sha256_file(raw_path),
                    "source_gain_map_version": version,
                    "canonical_formula": canonical_formula(source_type),
                    "canonical_min_log2_gain": float(canonical.min()),
                    "canonical_max_log2_gain": float(canonical.max()),
                    "canonical_mean_log2_gain": float(canonical.mean()),
                }
            )
            write_descriptor(sidecar_dir / f"{sample_id}.json", descriptor)
            lock_rows.append(descriptor)
        except Exception as exc:  # keep all failures for the final report
            failures.append({"sample_id": sample_id, "error": f"{type(exc).__name__}: {exc}"})
        if index % 100 == 0 or index == len(rows):
            print(f"scanned={index}/{len(rows)} generated={len(lock_rows)} failures={len(failures)}", flush=True)

    counts = {
        "iso_21496_1_tmap": sum(row["source_type"] == "iso_21496_1_tmap" for row in lock_rows),
        "legacy_apple": sum(row["source_type"] == "legacy_apple" for row in lock_rows),
    }
    if failures:
        _atomic_json(root / "reports" / "phase-a-label-errors.json", failures)
        raise SystemExit(f"Phase A label conversion failed for {len(failures)} samples")
    if require_counts and counts != {"iso_21496_1_tmap": 423, "legacy_apple": 388}:
        raise SystemExit(f"unexpected Phase A corpus counts: {counts}")
    lock = {
        "label_contract_id": LABEL_CONTRACT_ID,
        "label_contract_version": 2,
        "formula_version": FORMULA_VERSION,
        "manifest_sha256": _manifest_hash(manifest_path),
        "samples": len(lock_rows),
        "counts": counts,
        "unresolved": 0,
        "source_of_truth": "HyperDR_Model",
        "rows": [
            {
                "sample_id": row["sample_id"],
                "source_type": row["source_type"],
                "confidence": row["confidence"],
                "source_sha256": row["source_sha256"],
                "canonical_sha256": row["gain_file"]["sha256"],
                "width": row["gain_file"]["width"],
                "height": row["gain_file"]["height"],
            }
            for row in sorted(lock_rows, key=lambda value: str(value["sample_id"]))
        ],
    }
    _atomic_json(root / "reports" / "phase-a-corpus-lock.json", lock)
    _atomic_json(
        root / "manifests" / "phase_a_labels_v2.json",
        {"label_contract_id": LABEL_CONTRACT_ID, "rows": lock_rows},
    )
    return lock


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "datasets" / "hyperdr-apple")
    parser.add_argument("--require-counts", action="store_true")
    args = parser.parse_args()
    build(args.root, require_counts=args.require_counts)


if __name__ == "__main__":
    main()
