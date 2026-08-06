#!/usr/bin/env python3
"""Extract privacy-minimized Apple HDR Gain Map training assets.

The immutable HEIC files remain the source of truth. This script produces:
- a 1024-pixel-long-side SDR proxy with its ICC profile embedded;
- the native 8-bit Apple HDR Gain Map, losslessly stored as PNG;
- an optional native sky matte;
- a manifest without source filenames, GPS, or exact capture timestamps;
- a private capture index used only for leakage-safe grouping.

It intentionally does not interpret Apple Gain Map samples as canonical log gain.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
from collections import Counter
from datetime import datetime
from pathlib import Path
from typing import Any

import pillow_heif
from PIL import Image

from hyperdr_ml.geometry import aligned_long_side_size

GAIN_TYPE = "urn:com:apple:photo:2020:aux:hdrgainmap"
SKY_TYPE = "urn:com:apple:photo:2020:aux:semanticskymatte"
HEADROOM_RE = re.compile(rb"<HDRGainMap:HDRGainMapHeadroom>([^<]+)</HDRGainMap:HDRGainMapHeadroom>")
VERSION_RE = re.compile(rb"<HDRGainMap:HDRGainMapVersion>([^<]+)</HDRGainMap:HDRGainMapVersion>")


def atomic_write_bytes(path: Path, data: bytes, mode: int | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temp.write_bytes(data)
    os.replace(temp, path)
    if mode is not None:
        path.chmod(mode)


def atomic_write_jsonl(path: Path, rows: list[dict[str, Any]], mode: int | None = None) -> None:
    payload = "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n" for row in rows)
    atomic_write_bytes(path, payload.encode("utf-8"), mode)


def save_png_atomic(image: Image.Image, path: Path, **kwargs: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    image.save(temp, format="PNG", optimize=False, compress_level=6, **kwargs)
    os.replace(temp, path)


def exif_value(exif: Image.Exif, tag: int, default: Any = None) -> Any:
    value = exif.get(tag, default)
    if isinstance(value, bytes):
        try:
            return value.decode("utf-8", "replace").rstrip("\x00")
        except Exception:
            return default
    return value


def rational_to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError, ZeroDivisionError):
        return None


def parse_datetime(value: Any) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.strptime(str(value), "%Y:%m:%d %H:%M:%S")
    except ValueError:
        return None


def aux_xmp(aux_image: Any) -> bytes | None:
    # pillow-heif 1.3 does not expose auxiliary metadata publicly. The wrapped
    # libheif image does, so keep this compatibility access localized here.
    metadata = getattr(getattr(aux_image, "_c_image", None), "metadata", [])
    for item in metadata:
        data = item.get("data") if isinstance(item, dict) else None
        if isinstance(data, bytes) and b"HDRGainMap:" in data:
            return data
    return None


def parse_gain_xmp(xmp: bytes | None) -> tuple[int | None, float | None]:
    if not xmp:
        return None, None
    version_match = VERSION_RE.search(xmp)
    headroom_match = HEADROOM_RE.search(xmp)
    try:
        version = int(version_match.group(1)) if version_match else None
    except ValueError:
        version = None
    try:
        headroom = float(headroom_match.group(1)) if headroom_match else None
    except ValueError:
        headroom = None
    return version, headroom


def metadata_fingerprint(info: dict[str, Any]) -> str | None:
    metadata = info.get("metadata") or []
    digest = hashlib.sha256()
    found = False
    for item in metadata:
        if not isinstance(item, dict):
            continue
        data = item.get("data")
        if isinstance(data, bytes):
            digest.update(data)
            found = True
    return digest.hexdigest() if found else None


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "datasets/hyperdr-apple")
    parser.add_argument("--long-side", type=int, default=1024)
    args = parser.parse_args()

    root: Path = args.root
    originals = root / "originals"
    output = root / "extracted"
    sdr_dir = output / f"sdr_{args.long_side}"
    gain_dir = output / "apple_gain_raw"
    sky_dir = output / "sky_matte_raw"
    manifest_path = root / "manifests" / "samples.jsonl"
    private_capture_path = root / "private" / "capture-index.jsonl"

    files = sorted(originals.glob("*.heic"))
    if not files:
        raise SystemExit(f"No HEIC files found under {originals}")

    rows: list[dict[str, Any]] = []
    private_rows: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []
    counts: Counter[str] = Counter()

    for index, path in enumerate(files, 1):
        sample_id = path.stem
        try:
            heif = pillow_heif.open_heif(path, convert_hdr_to_8bit=False, bgr_mode=False)
            info = dict(heif.info or {})
            exif = Image.Exif()
            if info.get("exif"):
                exif.load(info["exif"])

            primary_decode = "native"
            try:
                primary = heif.to_pillow()
            except ValueError as exc:
                if "unrecognized image mode" not in str(exc) or int(info.get("bit_depth", 8)) <= 8:
                    raise
                # Pillow does not understand pillow-heif's RGBA;16 mode. Reopen
                # only for the SDR proxy; the immutable 10-bit HEIC is retained.
                fallback = pillow_heif.open_heif(path, convert_hdr_to_8bit=True, bgr_mode=False)
                primary = fallback.to_pillow()
                primary_decode = "8bit_fallback_from_high_bit_depth"
                counts["primary_8bit_fallback"] += 1
            proxy = primary.resize(
                aligned_long_side_size(primary.size, args.long_side),
                Image.Resampling.LANCZOS,
            )
            icc_profile = info.get("icc_profile")
            save_png_atomic(proxy, sdr_dir / f"{sample_id}.png", icc_profile=icc_profile or b"")

            aux = info.get("aux") or {}
            gain_ids = aux.get(GAIN_TYPE) or []
            sky_ids = aux.get(SKY_TYPE) or []
            gain_present = bool(gain_ids)
            gain_size = None
            gain_mode = None
            gain_version = None
            gain_headroom = None

            if gain_ids:
                gain_aux = heif.get_aux_image(gain_ids[0])
                gain_image = gain_aux.to_pillow()
                save_png_atomic(gain_image, gain_dir / f"{sample_id}.png")
                gain_size = list(gain_image.size)
                gain_mode = gain_image.mode
                gain_version, gain_headroom = parse_gain_xmp(aux_xmp(gain_aux))
                counts["gain"] += 1

            if sky_ids:
                sky_image = heif.get_aux_image(sky_ids[0]).to_pillow()
                save_png_atomic(sky_image, sky_dir / f"{sample_id}.png")
                counts["sky"] += 1

            capture_dt = parse_datetime(exif_value(exif, 36867) or exif_value(exif, 306))
            model = str(exif_value(exif, 272, "unknown")).strip() or "unknown"
            make = str(exif_value(exif, 271, "unknown")).strip() or "unknown"
            software = str(exif_value(exif, 305, "unknown")).strip() or "unknown"
            iso = exif_value(exif, 34855)
            if isinstance(iso, (tuple, list)):
                iso = iso[0] if iso else None

            rows.append({
                "sample_id": sample_id,
                "source_sha256": file_sha256(path),
                "source_bytes": path.stat().st_size,
                "make": make,
                "model": model,
                "software": software,
                "capture_month": capture_dt.strftime("%Y-%m") if capture_dt else None,
                "primary_size": list(primary.size),
                "primary_mode": primary.mode,
                "primary_decode": primary_decode,
                "primary_bit_depth": info.get("bit_depth"),
                "proxy_size": list(proxy.size),
                "color_profile": "icc" if icc_profile else "nclx" if info.get("nclx_profile") else "unspecified",
                "gain_map_present": gain_present,
                "gain_map_size": gain_size,
                "gain_map_mode": gain_mode,
                "gain_map_version": gain_version,
                "gain_map_headroom": gain_headroom,
                "sky_matte_present": bool(sky_ids),
                "iso": int(iso) if isinstance(iso, (int, float)) else None,
                "exposure_seconds": rational_to_float(exif_value(exif, 33434)),
                "f_number": rational_to_float(exif_value(exif, 33437)),
                "exposure_bias_ev": rational_to_float(exif_value(exif, 37380)),
                "focal_length_mm": rational_to_float(exif_value(exif, 37386)),
                "primary_metadata_sha256": metadata_fingerprint(info),
            })
            private_rows.append({
                "sample_id": sample_id,
                "capture_datetime": capture_dt.isoformat() if capture_dt else None,
                "orientation_exif": exif_value(exif, 274),
            })
            counts["parsed"] += 1
        except Exception as exc:
            failures.append({"sample_id": sample_id, "error_type": type(exc).__name__, "error": str(exc)[:500]})

        if index % 50 == 0 or index == len(files):
            print(f"processed={index}/{len(files)} gain={counts['gain']} sky={counts['sky']} failures={len(failures)}", flush=True)

    atomic_write_jsonl(manifest_path, rows, 0o644)
    atomic_write_jsonl(private_capture_path, private_rows, 0o600)
    atomic_write_jsonl(root / "reports" / "extraction-failures.jsonl", failures, 0o600)

    report = {
        "source_files": len(files),
        "parsed": counts["parsed"],
        "gain_maps": counts["gain"],
        "sky_mattes": counts["sky"],
        "primary_8bit_fallbacks": counts["primary_8bit_fallback"],
        "failures": len(failures),
        "sdr_proxy_long_side": args.long_side,
        "proxy_alignment": 16,
        "proxy_alignment_policy": "ceil each fitted dimension to a multiple of 16",
        "canonical_gain_generated": False,
        "note": "apple_gain_raw is an encoded auxiliary image, not canonical log2 gain",
    }
    atomic_write_bytes(root / "reports" / "extraction-summary.json", (json.dumps(report, indent=2) + "\n").encode(), 0o644)

    if failures:
        raise SystemExit(f"Extraction completed with {len(failures)} failures")


if __name__ == "__main__":
    main()
