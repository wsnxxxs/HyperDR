#!/usr/bin/env python3
"""Build the three capture fixtures the demonstration needs from one photograph.

The acceptance case is "a complete capture, a capture missing a field, and no
capture at all, on the same frame". A camera will not produce the middle one on
request, and the model's fallback rule is the part of this integration most
likely to be wrong in a way nobody notices, so the three files are derived here
rather than hunted for:

``full-exif.jpg``
    The frame carrying the Exif block HyperDR itself wrote when it exported the
    SDR rendition. All six ordinary tags are present.
``zero-bias.jpg``
    The same file with ExposureBiasValue rewritten to 0 EV. 0 is a value, not a
    missing tag, so model 2 must still use the capture path here.
``no-exif.jpg``
    The same frame with no Exif block at all. Model 2 must fall back to model 1
    and say which six fields it was missing.

The Exif block is taken from HyperDR's own output rather than synthesised, so the
fixtures exercise `make_minimal_exif` and `read_photo_metadata` against each
other instead of against a third-party writer.

    python HyperDR_Model/scripts/make_capture_fixtures.py \\
        --exe build-release/Release/HyperDR.exe --source photo.ARW --output-dir out/
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys

#: APP1 is where both Exif and XMP live; both are dropped to make a file with no
#: capture information while keeping the image itself untouched.
_APP1 = 0xE1
_SOS = 0xDA


def split_jpeg(data: bytes):
    """Return the leading (marker, segment) list and the offset of the scan data."""
    segments = []
    index = 2
    while index + 4 <= len(data) and data[index] == 0xFF:
        marker = data[index + 1]
        if marker == _SOS:
            break
        size = (data[index + 2] << 8) | data[index + 3]
        segments.append((marker, data[index:index + 2 + size]))
        index += 2 + size
    return segments, index


def without_exif(data: bytes) -> bytes:
    segments, scan = split_jpeg(data)
    return data[:2] + b"".join(segment for marker, segment in segments
                               if marker != _APP1) + data[scan:]


def exif_payloads(data: bytes) -> list[bytes]:
    segments, _scan = split_jpeg(data)
    return [segment for marker, segment in segments
            if marker == _APP1 and segment[4:10] == b"Exif\x00\x00"]


def zero_exposure_bias(segment: bytes) -> bytes:
    """Rewrite ExposureBiasValue (0x9204, SRATIONAL) to 0/1000 in place.

    The entry keeps its type and count, so the result is a well-formed tag whose
    value happens to be zero -- which is the case the presence rule is about.
    """
    body = bytearray(segment)
    tiff = body.index(b"Exif\x00\x00") + 6
    little = body[tiff:tiff + 2] == b"II"
    u16 = (lambda at: body[at] | (body[at + 1] << 8)) if little else (
        lambda at: (body[at] << 8) | body[at + 1])
    u32 = (lambda at: int.from_bytes(body[at:at + 4], "little")) if little else (
        lambda at: int.from_bytes(body[at:at + 4], "big"))

    def ifd_entries(offset):
        count = u16(offset)
        for position in range(count):
            at = offset + 2 + position * 12
            tag = u16(at)
            kind = u16(at + 2)
            count_here = u32(at + 4)
            if count_here * {1: 1, 3: 2, 4: 4, 5: 8, 10: 8}.get(kind, 1) > 4:
                value_at = tiff + u32(at + 8)
            else:
                value_at = at + 8
            yield tag, kind, count_here, value_at

    exif_ifd = None
    for tag, _kind, _count, value_at in ifd_entries(tiff + u32(tiff + 4)):
        if tag == 0x8769:
            exif_ifd = tiff + u32(value_at)
    if exif_ifd is None:
        raise SystemExit("the Exif block has no Exif IFD")
    for tag, kind, count, value_at in ifd_entries(exif_ifd):
        if tag != 0x9204:
            continue
        if kind != 10 or count != 1:
            raise SystemExit("ExposureBiasValue is not a single SRATIONAL")
        # Keep the sign-bearing numerator at zero and the denominator positive.
        body[value_at:value_at + 4] = (0).to_bytes(4, "little" if little else "big")
        return bytes(body)
    raise SystemExit("the Exif block has no ExposureBiasValue; the source camera "
                     "did not record one, so this fixture cannot be built")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--max-edge", type=int, default=1600)
    args = parser.parse_args(argv)

    args.output_dir.mkdir(parents=True, exist_ok=True)
    work = args.output_dir / ".fixture-work"
    work.mkdir(exist_ok=True)

    def run(*extra):
        completed = subprocess.run(
            [str(args.exe), *map(str, extra)], capture_output=True, check=False)
        if completed.returncode != 0:
            raise SystemExit(completed.stderr.decode("utf-8", errors="replace").strip())
        return completed.stdout

    # A plain JPEG of the frame, which carries no Exif at all: this is the
    # "capture settings were not recorded" case.
    run("thumbnail", args.source, "--output", work / "base.jpg",
        "--max-edge", args.max_edge, "--quality", "85")
    base = (work / "base.jpg").read_bytes()
    (args.output_dir / "no-exif.jpg").write_bytes(without_exif(base))

    # The same frame with the Exif HyperDR itself writes, which carries all six
    # ordinary tags.
    sdr = work / "sdr"
    sdr.mkdir(exist_ok=True)
    run("convert", args.source, "--output", sdr, "--encoding", "sdr-jpeg",
        "--quality", "92", "--report", work / "sdr-report.json")
    exported = next(path for path in sdr.iterdir() if path.suffix.lower() == ".jpg")
    payloads = exif_payloads(exported.read_bytes())
    if not payloads:
        raise SystemExit("the SDR export carries no Exif block")
    blank = without_exif(base)
    full = blank[:2] + b"".join(payloads) + blank[2:]
    (args.output_dir / "full-exif.jpg").write_bytes(full)
    (args.output_dir / "zero-bias.jpg").write_bytes(
        blank[:2] + zero_exposure_bias(payloads[0]) + b"".join(payloads[1:]) + blank[2:])

    # What the native reader makes of each, so the fixtures are known to be the
    # three cases they claim to be rather than only files of the right size.
    report = {}
    for name in ("full-exif.jpg", "zero-bias.jpg", "no-exif.jpg"):
        packet = run("model-gain", args.output_dir / name, "--ai-model", "research-exif-v1")
        size = int.from_bytes(packet[9:13], "little")
        metadata = json.loads(packet[13:13 + size])
        report[name] = {
            "inference_mode": metadata["inferenceMode"],
            "effective_model_id": metadata["effectiveModelId"],
            "fallback_reason": metadata.get("fallbackReason", ""),
        }
    (args.output_dir / "fixtures.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, ensure_ascii=False))

    expected = {"full-exif.jpg": "exif_assisted",
                "zero-bias.jpg": "exif_assisted",
                "no-exif.jpg": "pixel_only_fallback"}
    wrong = {name: value["inference_mode"] for name, value in report.items()
             if value["inference_mode"] != expected[name]}
    if wrong:
        print(f"fixtures did not behave as intended: {wrong}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
