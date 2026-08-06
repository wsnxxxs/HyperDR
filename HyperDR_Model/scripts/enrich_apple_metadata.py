#!/usr/bin/env python3
"""Enrich the privacy-minimized manifest with Apple HDR capture metadata.

Legacy Apple gain maps (XMP version 65536) omit HDRGainMapHeadroom. For
those samples, this script reads Apple MakerNote tags 0x21 (HDRHeadroom)
and 0x30 (HDRGain) and applies the piecewise headroom estimate used by the
public apple-hdr-heic reference implementation. Newer version 131072 maps
use their explicit XMP HDRGainMapHeadroom value.
"""

from __future__ import annotations

import json
import math
import os
import struct
from pathlib import Path
from typing import Any

import pillow_heif
from PIL import Image

ROOT = Path.home() / "datasets/hyperdr-apple"
MANIFEST = ROOT / "manifests" / "samples.jsonl"
PRIVATE_CAPTURE = ROOT / "private" / "capture-index.jsonl"


def atomic_jsonl(path: Path, rows: list[dict[str, Any]], mode: int) -> None:
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temp.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
    os.replace(temp, path)
    path.chmod(mode)


def rational(value: Any) -> float | None:
    try:
        return float(value) if value is not None else None
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def parse_apple_makernote(maker: bytes | None) -> dict[int, float]:
    """Parse signed-rational MakerNote entries using Apple-relative offsets.

    Apple MakerNote offsets in these files are relative to the beginning of
    the MakerNote blob, not the embedded TIFF byte-order marker.
    """
    if not maker:
        return {}
    byte_order_at = maker.find(b"MM")
    if byte_order_at < 0 or byte_order_at + 4 > len(maker):
        return {}
    count = struct.unpack_from(">H", maker, byte_order_at + 2)[0]
    entries_at = byte_order_at + 4
    if entries_at + count * 12 > len(maker):
        return {}
    values: dict[int, float] = {}
    for index in range(count):
        at = entries_at + index * 12
        tag, field_type, item_count, offset = struct.unpack_from(">HHII", maker, at)
        if field_type != 10 or item_count != 1 or offset + 8 > len(maker):
            continue
        numerator, denominator = struct.unpack_from(">ii", maker, offset)
        if denominator:
            values[tag] = numerator / denominator
    return values


def legacy_headroom(maker33: float, maker48: float) -> float:
    if maker33 < 1.0:
        stops = -20.0 * maker48 + 1.8 if maker48 <= 0.01 else -0.101 * maker48 + 1.601
    else:
        stops = -70.0 * maker48 + 3.0 if maker48 <= 0.01 else -0.303 * maker48 + 2.303
    return 2.0 ** max(stops, 0.0)


def main() -> None:
    rows = [json.loads(line) for line in MANIFEST.read_text(encoding="utf-8").splitlines()]
    private_by_id = {
        row["sample_id"]: row
        for row in (json.loads(line) for line in PRIVATE_CAPTURE.read_text(encoding="utf-8").splitlines())
    }
    failures: list[dict[str, str]] = []

    for index, row in enumerate(rows, 1):
        path = ROOT / "originals" / f"{row['sample_id']}.heic"
        try:
            heif = pillow_heif.open_heif(path, convert_hdr_to_8bit=False, bgr_mode=False)
            exif = Image.Exif()
            if heif.info.get("exif"):
                exif.load(heif.info["exif"])
            exif_ifd = exif.get_ifd(0x8769)
            maker = exif_ifd.get(0x927C)
            maker_tags = parse_apple_makernote(maker)
            maker33 = maker_tags.get(0x21)
            maker48 = maker_tags.get(0x30)

            row["iso"] = int(exif_ifd[0x8827]) if isinstance(exif_ifd.get(0x8827), (int, float)) else None
            row["exposure_seconds"] = rational(exif_ifd.get(0x829A))
            row["f_number"] = rational(exif_ifd.get(0x829D))
            row["exposure_bias_ev"] = rational(exif_ifd.get(0x9204))
            row["focal_length_mm"] = rational(exif_ifd.get(0x920A))
            row["focal_length_35mm"] = int(exif_ifd[0xA405]) if isinstance(exif_ifd.get(0xA405), int) else None
            row["apple_maker_hdr_headroom"] = maker33
            row["apple_maker_hdr_gain"] = maker48

            explicit = row.pop("gain_map_headroom", None)
            row["gain_map_headroom_xmp"] = explicit
            if not row["gain_map_present"]:
                row["canonical_headroom"] = None
                row["canonical_max_log2_gain"] = None
                row["headroom_source"] = None
                row["per_image_eligible"] = False
                row["degenerate_gain_label"] = False
            elif explicit is not None:
                headroom = float(explicit)
                row["canonical_headroom"] = headroom
                row["canonical_max_log2_gain"] = math.log2(headroom)
                row["headroom_source"] = "xmp_hdr_gain_map_headroom"
            elif maker33 is not None and maker48 is not None:
                headroom = legacy_headroom(maker33, maker48)
                row["canonical_headroom"] = headroom
                row["canonical_max_log2_gain"] = math.log2(headroom)
                row["headroom_source"] = "apple_makernote_piecewise_estimate"
            else:
                row["canonical_headroom"] = None
                row["canonical_max_log2_gain"] = None
                row["headroom_source"] = "unresolved"

            max_log2_gain = row.get("canonical_max_log2_gain")
            row["per_image_eligible"] = bool(
                max_log2_gain is not None
                and math.isfinite(float(max_log2_gain))
                and float(max_log2_gain) > 0.0
            )
            row["degenerate_gain_label"] = bool(
                row["gain_map_present"]
                and max_log2_gain is not None
                and math.isfinite(float(max_log2_gain))
                and float(max_log2_gain) == 0.0
            )

            private = private_by_id[row["sample_id"]]
            private["orientation_exif"] = exif.get(0x0112)
            offset = exif_ifd.get(0x9011)
            private["capture_timezone_offset"] = str(offset) if offset else None
        except Exception as exc:
            failures.append({"sample_id": row["sample_id"], "error": f"{type(exc).__name__}: {exc}"})

        if index % 100 == 0 or index == len(rows):
            resolved = sum(r.get("canonical_headroom") is not None for r in rows[:index] if r.get("gain_map_present"))
            print(f"processed={index}/{len(rows)} resolved_gain_headroom={resolved} failures={len(failures)}", flush=True)

    unresolved = [r["sample_id"] for r in rows if r.get("gain_map_present") and r.get("canonical_headroom") is None]
    invalid = [r["sample_id"] for r in rows if r.get("canonical_headroom") is not None and (not math.isfinite(r["canonical_headroom"]) or r["canonical_headroom"] < 1.0 or r["canonical_headroom"] > 32.0)]
    if failures or unresolved or invalid:
        report = {"failures": failures, "unresolved": unresolved, "invalid": invalid}
        (ROOT / "reports" / "metadata-enrichment-errors.json").write_text(json.dumps(report, indent=2) + "\n")
        raise SystemExit(f"Refusing to replace manifests: failures={len(failures)} unresolved={len(unresolved)} invalid={len(invalid)}")

    atomic_jsonl(MANIFEST, rows, 0o644)
    atomic_jsonl(PRIVATE_CAPTURE, list(private_by_id.values()), 0o600)
    summary = {
        "samples": len(rows),
        "gain_maps": sum(r["gain_map_present"] for r in rows),
        "headroom_from_xmp": sum(r.get("headroom_source") == "xmp_hdr_gain_map_headroom" for r in rows),
        "headroom_from_makernote": sum(r.get("headroom_source") == "apple_makernote_piecewise_estimate" for r in rows),
        "unresolved": 0,
        "per_image_eligible": sum(r.get("per_image_eligible", False) for r in rows),
        "degenerate_gain_labels": sum(r.get("degenerate_gain_label", False) for r in rows),
        "legacy_formula_provenance": "johncf/apple-hdr-heic metadata.py reverse-engineered implementation",
    }
    (ROOT / "reports" / "metadata-enrichment-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
