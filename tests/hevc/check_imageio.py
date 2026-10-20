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
    rises and the gain falls in raster order, so a swapped dimg order, a gain
    grid linked to the wrong image or a mis-cropped tile changes the sequence.
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


def png(width, height):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend((x * 255 // (width - 1), y * 255 // (height - 1), 64))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def export(cli, source, directory, encoding, depth=8, extra=()):
    directory.mkdir()
    report = directory / "report.json"
    result = subprocess.run([str(cli), "convert", str(source), "--output", str(directory), "--encoding", encoding,
                    "--depth", str(depth), "--report", str(report), "--overwrite", *extra],
                   check=False, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f"{encoding} export failed: {result.stderr}")
    files = list(directory.glob("*-hyperdr.*"))
    if len(files) != 1:
        raise RuntimeError(f"expected one {encoding} export: {files}")
    return files[0], json.loads(report.read_text())


def require_facts(result, width, height, depth, auxiliary):
    facts = result["image"]
    if (facts.get("width"), facts.get("height"), facts.get("bit_depth")) != (width, height, depth):
        raise RuntimeError(f"ImageIO dimensions/depth: {facts}")
    if auxiliary and result["gain_maps"]["iso"] is None:
        raise RuntimeError("ImageIO did not find the ISO auxiliary")


def check_cli(cli, renditions, probe, directory):
    source = directory / "source.png"
    source.write_bytes(png(128, 128))
    reference, _ = export(cli, source, directory / "sdr", "sdr-tiff")
    for depth in (8, 10):
        path, _ = export(cli, source, directory / f"adaptive{depth}", "adaptive", depth)
        result = json.loads(invoke(probe, path, "--reference", reference))
        require_facts(result, 128, 128, depth, True)
        psnr = result["reference"]["y_psnr_db"]
        if not isinstance(psnr, (int, float)) or not math.isfinite(psnr) or psnr < 38:
            raise RuntimeError(f"Adaptive {depth} SDR-base Y-PSNR: {psnr}")
        print(f"Adaptive {depth}: ImageIO size/depth/ISO auxiliary passed, base Y-PSNR {psnr:.6f} dB", flush=True)
    # CLI routing and independent decode of single-rendition HDR formats.
    for encoding in ("pq", "hlg"):
        path, _ = export(cli, source, directory / encoding, encoding, 10)
        require_facts(json.loads(invoke(probe, path)), 128, 128, 10, False)
    exact = directory / "exact-hdr"
    subprocess.run([str(renditions), str(exact)], check=True)
    for depth in (8, 10):
        candidate = exact / f"adaptive{depth}-hdr.f32"
        result = json.loads(invoke(probe, exact / f"adaptive{depth}.heic",
                                   env=dict(os.environ, HYPERDR_PROBE_DUMP_HDR=str(candidate))))
        require_facts(result, 256, 128, depth, True)
        metrics = json.loads(invoke(renditions, "--compare", exact / "reference-hdr.f32", candidate))
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in metrics.values()):
            raise RuntimeError(f"invalid Adaptive HDR metrics: {metrics}")
        if depth == 8:
            # Lead's U13 ruling: account for the unavoidable product YUV8 +
            # TPDF floor, measured now from the very same pre-encode base.
            # Never replace this with a frozen 4.83 (or tune the dither here).
            ideal = json.loads(invoke(renditions, "--compare", exact / "reference-hdr.f32",
                                      exact / "adaptive8-ideal-hdr.f32"))
            if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in ideal.values()):
                raise RuntimeError(f"invalid ideal YUV8 floor: {ideal}")
            print(f"Adaptive 8 live ideal YUV8+TPDF floor: {json.dumps(ideal)}", flush=True)
            delta_failed = (metrics["delta_e_itp_p99"] > ideal["delta_e_itp_p99"] + .75 or
                            metrics["delta_e_itp_mean"] > ideal["delta_e_itp_mean"] + .5)
        else:
            delta_failed = metrics["delta_e_itp_p99"] > 3
        if metrics["psnr_pq_db"] < 42 or delta_failed:
            raise RuntimeError(f"Adaptive {depth} HDR gate: {metrics}")
        print(f"Adaptive {depth} exact HDR: {json.dumps(metrics)}", flush=True)
    for encoding in ("pq", "hlg"):
        signal = exact / (encoding + "-signal.f32")
        result = json.loads(invoke(probe, exact / (encoding + ".heic"),
                                   env=dict(os.environ, HYPERDR_PROBE_DUMP_HDR_SIGNAL=str(signal))))
        require_facts(result, 256, 128, 10, False)
        expected_space = "kCGColorSpaceITUR_2100_" + encoding.upper()
        if result.get("hdr_signal_space") != expected_space:
            raise RuntimeError(f"HDR signal space: {result.get('hdr_signal_space')}")
        metrics = json.loads(invoke(renditions, "--compare-" + encoding, exact / "reference-hdr.f32", signal))
        if not all(isinstance(v, (int, float)) and math.isfinite(v) for v in metrics.values()):
            raise RuntimeError(f"invalid HDR metrics: {metrics}")
        mean_error = abs(metrics["candidate_mean"] / metrics["reference_mean"] - 1)
        if metrics["psnr_pq_db"] < 42 or metrics["delta_e_itp_p99"] > 3 or (encoding == "hlg" and mean_error > .02):
            raise RuntimeError(f"{encoding} same-rendition HDR gate: {metrics}, mean error={mean_error}")
        print(f"{encoding} exact HDR: {json.dumps(metrics)}, mean relative error={mean_error:.8f}", flush=True)
    from check_frame import check_frames
    check_frames(cli, renditions, probe, directory, export, source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", nargs="?", type=pathlib.Path)
    parser.add_argument("--writer-fixtures", type=pathlib.Path)
    parser.add_argument("--rendition-fixtures", type=pathlib.Path)
    parser.add_argument("--build-dir", type=pathlib.Path)
    parser.add_argument("--frame-baseline-cli", type=pathlib.Path, help="retained pre-E5 CLI for same-build q90 audit")
    args = parser.parse_args()
    if not args.cli and not args.writer_fixtures:
        parser.error("supply CLI or --writer-fixtures")
    cli = args.cli.resolve() if args.cli else None
    directory = (args.build_dir or cli.parent / "hevc-imageio").resolve()
    directory.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="imageio-", dir=directory) as temporary:
        root = pathlib.Path(temporary)
        probe = root / "imageio_probe"
        subprocess.run(["xcrun", "swiftc", "-O", str(pathlib.Path(__file__).with_name("imageio_probe.swift")), "-o", str(probe)], check=True)
        if args.writer_fixtures:
            check_writer(args.writer_fixtures.resolve(), probe, root)
        if cli:
            renditions = (args.rendition_fixtures or cli.with_name("heif_imageio_renditions")).resolve()
            check_cli(cli, renditions, probe, root)
            if args.frame_baseline_cli:
                from check_frame import check_q90_nonregression
                check_q90_nonregression(cli,args.frame_baseline_cli.resolve(),renditions,probe,root,export)


if __name__ == "__main__":
    main()
