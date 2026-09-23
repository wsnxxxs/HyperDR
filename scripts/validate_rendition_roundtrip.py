"""Exercise both renditions through all seven export formats and gain-map reimport.

Run against a codec-enabled build. Optional RAW/Apple fixtures stay outside Git.
The seven formats are input fixtures for a second Adaptive/Ultra HDR export;
single-version formats necessarily generate their missing rendition first.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import subprocess
import zlib

import numpy as np


FORMATS = ("adaptive", "ultrahdr", "pq", "hlg", "avif-pq", "avif-hlg", "sdr-jpeg")
NEUTRAL = ["--contrast", "1", "--vibrance", "0", "--pop", "0",
           "--exposure-bias", "0", "--gain-strength", "1", "--headroom", "4",
           "--headroom-max", "4", "--preview-max-edge", "256"]


def write_fixture(path: Path) -> None:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = b"".join(b"\0" + bytes(v for x in range(256) for v in (x, x, x)) for _ in range(128))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 128, 8, 2, 0, 0, 0))
                     + chunk(b"sRGB", b"\0") + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def run(exe: Path, *args: str) -> None:
    result = subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"{' '.join(map(str, args))}: {result.stderr or result.stdout}")


def preview(exe: Path, source: Path, output: Path) -> tuple[dict, np.ndarray]:
    run(exe, "preview-frame", source, "--output", output, *NEUTRAL)
    data = output.read_bytes()
    if data[:8] != b"HYPREV1\n":
        raise AssertionError("Expected two-plane preview packet")
    length, = struct.unpack_from("<I", data, 8)
    meta = json.loads(data[12:12 + length])
    planes = np.frombuffer(data, dtype="<f4", offset=12 + length).reshape(2, meta["height"], meta["width"], 3)
    if not np.isfinite(planes).all():
        raise AssertionError("Preview contains non-finite pixels")
    return meta, planes


def convert(exe: Path, source: Path, directory: Path, encoding: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    report = directory / "report.json"
    depth = "8" if encoding in ("ultrahdr", "sdr-jpeg") else "10"
    limits = ["--headroom", "2.3", "--headroom-max", "2.3"] if encoding in ("hlg", "avif-hlg") else []
    run(exe, "convert", source, "--output", directory, "--encoding", encoding,
        "--quality", "100", "--depth", depth, "--overwrite", "--report", report, *NEUTRAL, *limits)
    result = json.loads(report.read_text(encoding="utf-8"))["files"][0]
    if encoding == "ultrahdr":
        actual_gain = max(0.0, result["gain_map"]["max_stops"])
        if abs(result["headroom_stops"] - actual_gain) > .001:
            raise AssertionError("Ultra HDR capacity differs from the stored maximum gain")
    return Path(result["output"])


def error(reference: np.ndarray, candidate: np.ndarray) -> dict:
    weights = np.array([0.22897456, 0.69173852, 0.07928691])
    ref_y, got_y = reference @ weights, candidate @ weights
    return {"mean_luminance_ratio": float(got_y.mean() / max(ref_y.mean(), 1e-8)),
            "relative_mae": float(np.abs(candidate - reference).mean() / max(np.abs(reference).mean(), 1e-8))}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("output/dual-rendition-validation/roundtrip"))
    parser.add_argument("--raw", type=Path)
    parser.add_argument("--authored", type=Path, action="append", default=[])
    args = parser.parse_args()
    args.executable = args.executable.resolve()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    fixture = args.output / "neutral-ramp.png"
    write_fixture(fixture)
    sources = [("sdr-source", fixture)]
    sources.extend((fmt, convert(args.executable, fixture, args.output / "inputs" / fmt, fmt)) for fmt in FORMATS)
    if args.raw:
        sources.append(("raw-source", args.raw.resolve()))
        for fmt in ("adaptive", "ultrahdr"):
            sources.append(("raw-" + fmt, convert(args.executable, args.raw.resolve(), args.output / "inputs" / ("raw-" + fmt), fmt)))
    sources.extend(("authored-" + str(i), path.resolve()) for i, path in enumerate(args.authored))
    results, failures = [], []
    for label, source in sources:
        meta, expected = preview(args.executable, source, args.output / f"{label}-reference.hpf")
        authored = label in ("adaptive", "ultrahdr", "raw-adaptive", "raw-ultrahdr") or label.startswith("authored-")
        if authored and meta["inputDomain"] != "dual-rendition":
            failures.append(f"{label}: authored input classified as {meta['inputDomain']}")
        for fmt in ("adaptive", "ultrahdr"):
            candidate = convert(args.executable, source, args.output / label / fmt, fmt)
            got_meta, actual = preview(args.executable, candidate, args.output / f"{label}-{fmt}.hpf")
            metrics = {"input": label, "output": fmt, "input_domain": meta["inputDomain"],
                       "decoded_domain": got_meta["inputDomain"], "sdr": error(expected[0], actual[0]),
                       "hdr": error(expected[1], actual[1])}
            # JPEG/HEVC and the single-channel Adaptive projection are lossy.
            # Five percent catches the old 7–23% SDR darkening; no bit-exact codec claim.
            passed = got_meta["inputDomain"] == "dual-rendition" and all(
                abs(metrics[plane]["mean_luminance_ratio"] - 1) < .05 and metrics[plane]["relative_mae"] < .10
                for plane in ("sdr", "hdr"))
            metrics["passed"] = passed
            results.append(metrics)
            print(json.dumps(metrics), flush=True)
            if not passed:
                failures.append(f"{label} -> {fmt}")
    (args.output / "summary.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
    if failures:
        raise SystemExit("Rendition regression: " + ", ".join(failures))


if __name__ == "__main__":
    main()
