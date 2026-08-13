#!/usr/bin/env python3
"""Generate or verify the frozen synthetic Adaptive HDR fixtures for T2.

The checked-in HEIC pair is intentionally tiny.  The probe is encoded once
with gamma=2, then the control is made by changing only that rational in the
ISO ToneMapImage payload.  Verification therefore proves that codec output,
base pixels, gain pixels, and every other metadata byte are identical.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import shutil
import struct
import subprocess
import tempfile
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
SPEC_PATH = HERE / "fixture_spec.json"
MANIFEST_PATH = HERE / "fixture_manifest.json"


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_source(path: pathlib.Path) -> str:
    """Identify a text source by content, with line endings normalised to LF.

    Every recorded source is text under `* text=auto`, so a Windows checkout
    holds CRLF exactly where a macOS or Linux checkout holds LF. Hashing the
    bytes on disk would identify the checkout instead of the content, and would
    fail on the one platform this gate has to run on. Fixture binaries and the
    generator executable keep the plain byte hash above."""
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def write_png(path: pathlib.Path, width: int, height: int, rgb: list[int]) -> None:
    if len(rgb) != 3 or any(value < 0 or value > 255 for value in rgb):
        raise ValueError("base.rgb8 must contain three bytes")
    signature = b"\x89PNG\r\n\x1a\n"

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    row = b"\0" + bytes(rgb) * width
    data = signature
    data += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    data += chunk(b"IDAT", zlib.compress(row * height, level=9))
    data += chunk(b"IEND", b"")
    path.write_bytes(data)


def gain_samples(spec: dict) -> list[float]:
    """Row-major canonical log2 gain for the whole grid.

    Written as a pattern rather than a literal grid: the geometry has to clear
    the encoder's 64-pixel padding threshold, and four thousand numbers spelled
    out in the spec would hide what the fixture actually is."""
    gain = spec["gain"]
    pattern = gain["pattern"]
    if pattern["type"] != "alternating_columns":
        raise ValueError(f"unsupported gain pattern: {pattern['type']}")
    values = pattern["canonical_log2_stops"]
    return [
        float(values[x % len(values)])
        for _ in range(gain["height"])
        for x in range(gain["width"])
    ]


def rational_payload(spec: dict, gamma_numerator: int) -> bytes:
    metadata = spec["metadata_common"]
    payload = struct.pack(
        ">BHHB", 0, metadata["minimum_version"], metadata["writer_version"], metadata["flags"]
    )
    for name in (
        "base_headroom",
        "alternate_headroom",
        "gain_min",
        "gain_max",
    ):
        value = metadata[name]
        payload += struct.pack(">iI", value["numerator"], value["denominator"])
    payload += struct.pack(">iI", gamma_numerator, 1)
    for name in ("base_offset", "alternate_offset"):
        value = metadata[name]
        payload += struct.pack(">iI", value["numerator"], value["denominator"])
    if len(payload) != 62:
        raise AssertionError(f"unexpected ToneMapImage payload length: {len(payload)}")
    return payload


def external_sidecar(spec: dict, gain_path: pathlib.Path) -> dict:
    metadata = dict(spec["metadata_common"])
    metadata["gamma"] = {"numerator": 2, "denominator": 1}
    return {
        "label_contract_id": "hyperdr.apple-gain-label/v2",
        "gain_grid_size": [spec["gain"]["width"], spec["gain"]["height"]],
        "gain_file": {
            "format": "raw_float32_with_required_json_sidecar",
            "endianness": "little",
            "scale": "signed_log2_gain",
            "width": spec["gain"]["width"],
            "height": spec["gain"]["height"],
            "byte_length": gain_path.stat().st_size,
            "sha256": sha256(gain_path),
        },
        "gain_metadata": metadata,
    }


def inspect_metadata(hyperdr: pathlib.Path, fixture: pathlib.Path) -> dict:
    completed = subprocess.run(
        [str(hyperdr), "inspect", str(fixture), "--json"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    document = json.loads(completed.stdout)
    if not document.get("structurally_valid") or not document.get("tmap_metadata_present"):
        raise RuntimeError(f"fixture did not pass HyperDR inspection: {fixture}")
    return document["tmap_metadata"]


def regenerate(hyperdr: pathlib.Path) -> None:
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    fixtures_dir = HERE / "fixtures"
    fixtures_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="hyperdr-macos-t2-") as temporary:
        work = pathlib.Path(temporary)
        output = work / "encoded"
        output.mkdir()
        base_path = work / "base.png"
        gain_path = work / "gain.f32"
        sidecar_path = work / "gain.json"
        write_png(
            base_path,
            spec["base"]["width"],
            spec["base"]["height"],
            spec["base"]["rgb8"],
        )
        gain_path.write_bytes(
            struct.pack("<" + "f" * len(gain_samples(spec)), *gain_samples(spec))
        )
        sidecar_path.write_text(
            json.dumps(external_sidecar(spec, gain_path), indent=2) + "\n",
            encoding="utf-8",
        )
        subprocess.run(
            [
                str(hyperdr),
                "convert",
                str(base_path),
                "--output",
                str(output),
                "--encoding",
                "adaptive",
                "--external-gain",
                str(gain_path),
                "--external-gain-report",
                str(sidecar_path),
                "--quality",
                "100",
                "--depth",
                "8",
                "--overwrite",
            ],
            check=True,
        )
        encoded = output / "base-hyperdr.heic"
        if not encoded.is_file():
            raise RuntimeError("HyperDR did not create the expected HEIC")

        # Validate the complete pair before touching the checked-in fixtures.
        # A failed regeneration must not leave one half of the frozen pair new.
        probe_path = work / "gamma-2-probe.heic"
        control_path = work / "gamma-1-control.heic"
        shutil.copyfile(encoded, probe_path)
        probe = probe_path.read_bytes()
        probe_payload = rational_payload(spec, 2)
        payload_offset = probe.find(probe_payload)
        if payload_offset < 0 or probe.find(probe_payload, payload_offset + 1) >= 0:
            raise RuntimeError("expected one exact gamma=2 ToneMapImage payload")
        control = bytearray(probe)
        gamma_last_byte_offset = payload_offset + 41
        if control[gamma_last_byte_offset] != 2:
            raise RuntimeError("unexpected gamma numerator encoding")
        control[gamma_last_byte_offset] = 1
        control_path.write_bytes(control)

        probe_metadata = inspect_metadata(hyperdr, probe_path)
        control_metadata = inspect_metadata(hyperdr, control_path)
        if probe_metadata["gamma"] != {"numerator": 2, "denominator": 1}:
            raise RuntimeError("probe gamma was not preserved")
        if control_metadata["gamma"] != {"numerator": 1, "denominator": 1}:
            raise RuntimeError("control gamma patch was not accepted")

        staged = []
        try:
            for source, name in (
                (control_path, "gamma-1-control.heic"),
                (probe_path, "gamma-2-probe.heic"),
            ):
                target = fixtures_dir / name
                temporary_target = fixtures_dir / f".{name}.new"
                shutil.copyfile(source, temporary_target)
                staged.append((temporary_target, target))
            for temporary_target, target in staged:
                temporary_target.replace(target)
        finally:
            for temporary_target, _ in staged:
                temporary_target.unlink(missing_ok=True)

    differing_offsets = [
        index
        for index, (control_byte, probe_byte) in enumerate(zip(control, probe))
        if control_byte != probe_byte
    ]
    if len(control) != len(probe) or differing_offsets != [gamma_last_byte_offset]:
        raise RuntimeError("control and probe differ outside the gamma numerator")

    sources = [
        "modules/codec/src/heif_encoder.cpp",
        "modules/gainmap/src/external.cpp",
        "modules/container/src/iso_gain_map.cpp",
        "modules/gainmap/src/reconstruct.cpp",
        "tests/macos_t2/generate_fixtures.py",
        "tests/macos_t2/fixture_spec.json",
    ]
    manifest = {
        "schema_version": 1,
        "protocol_id": spec["protocol_id"],
        "generated_from_git_commit": subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=ROOT,
            check=True,
            stdout=subprocess.PIPE,
            text=True,
        ).stdout.strip(),
        "generator_executable": {
            "path_recorded_for_provenance_only": str(hyperdr.resolve()),
            "sha256": sha256(hyperdr),
        },
        "source_sha256": {name: sha256_source(ROOT / name) for name in sources},
        "fixtures": [
            {
                "id": fixture["id"],
                "path": fixture["filename"],
                "gamma": fixture["gamma"],
                "byte_length": (HERE / fixture["filename"]).stat().st_size,
                "sha256": sha256(HERE / fixture["filename"]),
            }
            for fixture in spec["fixtures"]
        ],
        "pair_invariant": {
            "same_byte_length": True,
            "differing_byte_count": 1,
            "differing_absolute_offsets": differing_offsets,
            "control_byte_hex": "01",
            "probe_byte_hex": "02",
            "tmap_payload_absolute_offset": payload_offset,
            "gamma_numerator_last_byte_offset_within_payload": 41,
            "statement": "The files differ only in the final byte of the big-endian gamma numerator (1 versus 2).",
        },
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    verify()


def verify() -> None:
    spec = json.loads(SPEC_PATH.read_text(encoding="utf-8"))
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    if manifest.get("protocol_id") != spec.get("protocol_id"):
        raise RuntimeError("fixture manifest protocol does not match the spec")
    for relative, expected in manifest.get("source_sha256", {}).items():
        source = ROOT / relative
        if not source.is_file() or sha256_source(source) != expected:
            raise RuntimeError(f"fixture source identity mismatch: {relative}")
    records = {record["id"]: record for record in manifest["fixtures"]}
    payload_offsets = {}
    blobs = {}
    for fixture in spec["fixtures"]:
        record = records.get(fixture["id"])
        if (record is None or record["path"] != fixture["filename"] or
                record["gamma"] != fixture["gamma"]):
            raise RuntimeError(f"missing manifest record for {fixture['id']}")
        path = HERE / fixture["filename"]
        if path.stat().st_size != record["byte_length"] or sha256(path) != record["sha256"]:
            raise RuntimeError(f"fixture identity mismatch: {fixture['id']}")
        blob = path.read_bytes()
        blobs[fixture["id"]] = blob
        payload = rational_payload(spec, fixture["gamma"]["numerator"])
        offset = blob.find(payload)
        if offset < 0 or blob.find(payload, offset + 1) >= 0:
            raise RuntimeError(f"fixture lacks one exact tmap payload: {fixture['id']}")
        payload_offsets[fixture["id"]] = offset
    control = blobs["gamma-1-control"]
    probe = blobs["gamma-2-probe"]
    differences = [index for index, pair in enumerate(zip(control, probe)) if pair[0] != pair[1]]
    invariant = manifest["pair_invariant"]
    if len(control) != len(probe) or differences != invariant["differing_absolute_offsets"]:
        raise RuntimeError("fixture pair violates the only-gamma byte invariant")
    if len(differences) != 1 or differences[0] != payload_offsets["gamma-1-control"] + 41:
        raise RuntimeError("fixture difference is not the gamma numerator")
    print("macOS T2 fixture manifest and only-gamma invariant passed")


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("verify")
    regenerate_parser = subparsers.add_parser("regenerate")
    regenerate_parser.add_argument("--hyperdr", type=pathlib.Path, required=True)
    arguments = parser.parse_args()
    if arguments.command == "verify":
        verify()
    else:
        regenerate(arguments.hyperdr)


if __name__ == "__main__":
    main()
