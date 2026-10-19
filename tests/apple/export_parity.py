"""Compare complete Kit exports with the same build's CLI, without masking bytes.

Outputs are ephemeral comparisons; this does not record Ultra HDR goldens.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[2]


def run(*args: str, env=None) -> str:
    result = subprocess.run(args, cwd=ROOT, env=env, check=False,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=180)
    if result.returncode:
        raise RuntimeError(f"{args[0]} exited {result.returncode}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def png(width: int, height: int, alpha: bool = False) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            rows.extend((x * 255 // max(1, width - 1), y * 255 // max(1, height - 1), 64))
            if alpha:
                rows.append(160)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if alpha else 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def main() -> None:
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    package = ROOT / "apps/apple/Packages/HyperDRKit"
    scratch = ROOT / "build-apple/swift-kit"
    run("swift", "build", "--package-path", str(package), "--scratch-path", str(scratch), "--product", "HyperDRKitParity", env=env)
    binary_dir = Path(run("swift", "build", "--package-path", str(package), "--scratch-path", str(scratch), "--show-bin-path", env=env).strip())
    cli = ROOT / "build-apple/HyperDR"
    with tempfile.TemporaryDirectory(prefix="hyperdr-export-parity-") as temporary:
        root = Path(temporary)
        clock = root / "frozen-time.dylib"
        run("xcrun", "clang", "-dynamiclib", str(ROOT / "tests/capi/frozen_time.c"), "-o", str(clock), env=env)
        frozen = dict(env, DYLD_INSERT_LIBRARIES=str(clock))
        source = root / "sample.png"
        source.write_bytes(png(128, 96))
        cases = [(encoding, None) for encoding in ("sdr-jpeg", "sdr-tiff", "avif-pq", "avif-hlg", "iso-gainmap-jpeg")]
        cases += [(encoding, style) for style in ("gallery", "story") for encoding in ("iso-gainmap-jpeg", "sdr-tiff")]
        cases += [("iso-gainmap-jpeg", "raw"), ("sdr-tiff", "lut"), ("iso-gainmap-jpeg", "ai")]
        cases += [("adaptive", None), ("adaptive", "depth10"), ("pq", None), ("hlg", None)]
        lut = root / "private-look.cube"
        lut.write_text('LUT_3D_SIZE 2\n' + '\n'.join(
            f'{r} {g} {b}' for b in (0, 1) for g in (0, 1) for r in (0, 1)) + '\n')
        for index, (encoding, style) in enumerate(cases):
            adaptive10 = style == "depth10"
            depth = 10 if adaptive10 or encoding in ("pq", "hlg") else 8
            style = None if adaptive10 else style
            case_source = (ROOT / "tests/fixtures/gain-map-jpeg/iso-mono.jpg" if adaptive10 else
                           ROOT / "build/fixtures/sony-ilce-7s.ARW" if style == "raw" else source)
            mode = style
            style = None if style in ("raw", "lut", "ai") else style
            case = root / str(index)
            case.mkdir()
            options = case / "options.json"
            values = {"encoding": encoding, "brightness": .612345, "contrast": 1.123456}
            if adaptive10:
                # The editor normally supplies the actual source domain. This
                # fixture is an authored ISO HDR JPEG, so select its HDR default.
                values["sourceDomain"] = "dual-rendition"
            if mode == "ai":
                values.update(useModel=True, modelId="research-cnn-v1")
            options.write_text(json.dumps(values))
            destination = case / "saved"
            destination.mkdir()
            args = [str(binary_dir / "HyperDRKitParity"), str(case_source), str(options), str(case / "work"), str(destination)]
            if style:
                spec = {"schema": "hyperdr.frame/v1", "background": "#F5F3EE"}
                if style == "gallery":
                    spec.update(margins=.06, caption=.13,
                                shadow={"opacity": .10, "blur": .012, "offset": .004})
                else:
                    spec.update(margins={"top": .055, "right": .055, "bottom": .04, "left": .055},
                                caption=.16, aspect={"width": 9, "height": 16, "topShare": .42})
                spec_path = case / "spec.json"
                spec_path.write_text(json.dumps(spec))
                frame = {"spec": spec}
                if style == "gallery":
                    layout = json.loads(run(str(cli), "frame-layout", str(spec_path), "--width", "128", "--height", "96", env=frozen))
                    frame["overlayPNG"] = base64.b64encode(png(layout["caption"]["width"], layout["caption"]["height"], True)).decode()
                frame_path = case / "frame-input.json"
                frame_path.write_text(json.dumps(frame))
                args.append(str(frame_path))
            output = run(*args, env=dict(frozen, HYPERDR_PARITY_LUT=str(lut)) if mode == "lut" else frozen)
            result = json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{"argv":')))
            argv = result["diagnosticArgv"]
            assert argv[0] == "HyperDR"
            assert all(not arg.startswith("/") and str(Path.home()) not in arg for arg in argv), argv
            assert all(arg.isascii() for arg in argv), argv
            output_dir = case / "cli"
            paths = {"photo" + case_source.suffix: str(case_source), "out": str(output_dir),
                     "out/report.json": str(case / "cli-report.json"), "look.cube": str(lut)}
            if style:
                paths["frame.json"] = result["argv"][result["argv"].index("--frame") + 1]
            if mode == "lut":
                assert "look.cube" in argv
            if mode == "ai":
                assert "--ai-model" in argv, argv
            if encoding in ("adaptive", "pq", "hlg"):
                assert argv[argv.index("--depth") + 1] == str(depth), (encoding, depth, argv)
            argv = [str(cli)] + [paths.get(arg, arg) for arg in argv[1:]]
            if style:
                assert "--frame" in argv
            run(*argv, env=frozen)
            kit_file = Path(result["path"])
            cli_file = output_dir / kit_file.name
            actual = hashlib.sha256(kit_file.read_bytes()).hexdigest()
            expected = hashlib.sha256(cli_file.read_bytes()).hexdigest()
            assert actual == expected, (encoding, style, actual, expected)
            print(f"PASS {encoding} {mode or 'plain'} depth={depth} {actual}", flush=True)
    print(f"export parity: {len(cases)}/{len(cases)} byte-identical", flush=True)


if __name__ == "__main__":
    main()
