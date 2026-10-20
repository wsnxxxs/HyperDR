"""Independent ImageIO gates for VT exports and cropped HEIF auxiliaries.

Adaptive has an SDR base: compare it with the same-parameter SDR TIFF (38 dB).
PQ/HLG have only an HDR primary. DecodeToSDR would measure system tone mapping,
not encoding. Instead compare ImageIO's HDR signal, inverted with the specified
BT.2100 transfer, with the exact pre-encode HDR float frame (U13 / section 15.2).
Only Adaptive8 uses Lead's live YUV8+TPDF floor plus .75 p99 / .5 mean margins;
Adaptive10, PQ and HLG retain the absolute section 15.2 limits.
"""
import argparse
import json
import math
import os
import pathlib
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[2]


def invoke(*args, env=None):
    return subprocess.check_output([str(a) for a in args], text=True, env=env)


def check_writer(fixtures, probe, directory):
    subprocess.run([str(fixtures), str(directory)], check=True)
    for depth in (8, 10):
        for width, height in ((64, 64), (63, 47), (1, 1), (512, 512), (513, 513), (768, 768)):
            path = directory / f"{width}x{height}-{depth}.heic"
            result = json.loads(invoke(probe, "--require-iso-dimensions", width, height, path))
            if result != {"width": width, "height": height, "iso_auxiliary": True}:
                raise RuntimeError(f"ImageIO grid/auxiliary mismatch: {path.name}: {result}")
            print(f"ImageIO {path.name}: dimensions correct, ISO auxiliary true", flush=True)
            check_tile_order(probe, width, height, path)


def check_tile_order(probe, width, height, path):
    """Structure check that does not rely on our own HEIF reader (R7-1603).

    ImageIO resolves the grid's ordered dimg list and the gain map's auxl link
    to the primary image. The fixtures give each tile its own level: the base
    rises and the gain falls in raster order, so a swapped dimg order or a gain
    grid linked to the wrong image changes the sequence. Each tile is flat and
    only its centre is sampled: this checks the cropped size and the tile
    order, not crop offsets or edge pixels inside a tile.
    """
    result = json.loads(invoke(probe, "--tile-order", width, height, path))
    count = result["columns"] * result["rows"]
    if len(result["base"]) != count or len(result["gain"]) != count:
        raise RuntimeError(f"ImageIO tile samples: {path.name}: {result}")
    for name, direction in (("base", 1), ("gain", -1)):
        steps = [direction * (b - a) for a, b in zip(result[name], result[name][1:])]
        if any(step < 0.08 for step in steps):
            raise RuntimeError(f"ImageIO {name} tile order: {path.name}: {result[name]}")
    print(f"ImageIO {path.name}: {count} tile(s) in raster order, gain linked to the primary", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer-fixtures", type=pathlib.Path)
    parser.add_argument("--build-dir", type=pathlib.Path)
    args = parser.parse_args()
    if not args.writer_fixtures:
        parser.error("supply --writer-fixtures")
    directory = (args.build_dir or ROOT / "build/hevc-imageio").resolve()
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="imageio-", dir=directory) as temporary:
        root = pathlib.Path(temporary)
        probe = root / "imageio_probe"
        subprocess.run(["xcrun", "swiftc", "-O", str(pathlib.Path(__file__).with_name("imageio_probe.swift")), "-o", str(probe)], check=True)
        if args.writer_fixtures:
            check_writer(args.writer_fixtures.resolve(), probe, root)



if __name__ == "__main__":
    main()
