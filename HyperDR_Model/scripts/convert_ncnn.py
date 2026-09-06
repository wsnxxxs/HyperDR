#!/usr/bin/env python3
"""Convert the frozen Direct-v3 inference graph to ncnn with pnnx.

The repository does not vendor a converter binary.  This script therefore
requires a real ``pnnx`` executable (the pinned version used for the checked
in model is recorded in the output manifest), and refuses to continue when it
is missing or when pnnx emits an unsupported layer.  The ncnn graph is the
five-feature core emitted by :mod:`export_onnx`; the native runtime constructs
the two deterministic feature planes (log luminance and clipping) before
feeding blob ``in0``.  This avoids silently dropping the clipping comparison,
which older ncnn converters cannot represent.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any


MODEL_STRIDE = 16
DEFAULT_HEIGHT = 192
DEFAULT_WIDTH = 256
CONVERTER_VERSION = "20260526"
OUTPUT_PARAM = "production-v3.ncnn.param"
OUTPUT_BIN = "production-v3.ncnn.bin"
OUTPUT_MANIFEST = "production-v3.ncnn.json"


# PNNX's ncnn backend should lower the core graph to this set.  Keeping this
# allow-list makes a converter upgrade fail closed instead of shipping an
# artifact with an ignored custom layer that ncnn cannot execute.
ALLOWED_LAYERS = {
    "Input",
    "Split",
    "Slice",
    "Eltwise",
    "Clip",
    "UnaryOp",
    "BinaryOp",
    "Convolution",
    "ConvolutionDepthWise",
    "GroupNorm",
    "Swish",
    "Pooling",
    "Concat",
    "Sigmoid",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_path(path: Path) -> str:
    """Use a repository-relative path when the asset lives below cwd."""
    try:
        return path.resolve().relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        return str(path)


def _size(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{name} must be an integer") from exc
    if parsed < MODEL_STRIDE or parsed % MODEL_STRIDE:
        raise argparse.ArgumentTypeError(
            f"{name} must be a positive multiple of {MODEL_STRIDE}"
        )
    return parsed


def _find_pnnx(explicit: str | None) -> Path:
    candidates: list[Path] = []
    if explicit:
        candidates.append(Path(explicit).expanduser())
    found = shutil.which("pnnx")
    if found:
        candidates.append(Path(found))
    # A pip install may expose the binary only inside the package directory.
    try:
        import pnnx  # type: ignore

        candidates.append(Path(pnnx.EXEC_PATH))
    except (ImportError, AttributeError):
        pass
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise SystemExit(
        "pnnx was not found; install the pinned converter (`pip install "
        f"pnnx=={CONVERTER_VERSION}`) or pass --pnnx <path>"
    )


def _run_pnnx(
    executable: Path,
    onnx: Path,
    param: Path,
    weights: Path,
    *,
    height: int,
    width: int,
    second_height: int | None,
    second_width: int | None,
) -> str:
    command = [
        str(executable),
        str(onnx),
        f"inputshape=[1,5,{height},{width}]",
        "device=cpu",
        "fp16=0",
        "optlevel=2",
        f"ncnnparam={param}",
        f"ncnnbin={weights}",
    ]
    if second_height is not None and second_width is not None:
        command.append(f"inputshape2=[1,5,{second_height},{second_width}]")
    try:
        result = subprocess.run(
            command,
            check=False,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except OSError as exc:
        raise SystemExit(f"could not execute pnnx at {executable}: {exc}") from exc
    if result.returncode != 0:
        raise SystemExit(
            f"pnnx failed with exit code {result.returncode}; no ncnn asset was accepted\n"
            f"{result.stdout}"
        )
    return result.stdout


def _check_param(path: Path) -> tuple[str, str, list[str]]:
    lines = path.read_text(encoding="utf-8", errors="strict").splitlines()
    if len(lines) < 2:
        raise SystemExit(f"ncnn param is unexpectedly short: {path}")
    layers: list[str] = []
    input_blob: str | None = None
    output_blob: str | None = None
    for line in lines[2:]:
        fields = line.split()
        if not fields:
            continue
        layer = fields[0]
        layers.append(layer)
        if layer not in ALLOWED_LAYERS:
            raise SystemExit(
                f"pnnx emitted unsupported ncnn layer {layer!r}; refusing to "
                "ship an artifact that may silently lose model behavior"
            )
        if layer == "Input" and len(fields) >= 5:
            input_blob = fields[4]
        if "out0" in fields:
            output_blob = "out0"
    # The standard pnnx names are deliberately asserted because the C++
    # runtime and the generated verification harness use these names.
    if input_blob is None:
        input_blob = "in0"
    if output_blob is None:
        output_blob = "out0"
    if "in0" not in " ".join(lines) or "out0" not in " ".join(lines):
        raise SystemExit("ncnn graph does not expose the required in0/out0 blobs")
    return input_blob, output_blob, layers


def _export_core_onnx(
    checkpoint: Path,
    destination: Path,
    *,
    height: int,
    width: int,
    dynamic: bool,
) -> dict[str, Any]:
    model_root = Path(__file__).resolve().parents[1]
    if str(model_root) not in sys.path:
        sys.path.insert(0, str(model_root))
    from export_onnx import export_onnx

    return export_onnx(
        checkpoint=checkpoint,
        output=destination,
        graph_kind="features",
        height=height,
        width=width,
        batch=1,
        opset=18,
        dynamic=dynamic,
        metadata_path=None,
    )


def convert_ncnn(
    *,
    checkpoint: Path,
    output_dir: Path,
    pnnx: str | None,
    height: int,
    width: int,
    second_height: int | None,
    second_width: int | None,
    source_onnx: Path | None,
) -> dict[str, Any]:
    executable = _find_pnnx(pnnx)
    output_dir.mkdir(parents=True, exist_ok=True)
    output_param = output_dir / OUTPUT_PARAM
    output_bin = output_dir / OUTPUT_BIN
    output_manifest = output_dir / OUTPUT_MANIFEST

    # Keep intermediate pnnx files outside the source tree.  A failed
    # conversion cannot leave a partially valid .param/.bin pair behind.
    source_manifest_file = ""
    source_manifest_sha256 = ""
    source_kind = "onnx"
    onnx_metadata: dict[str, Any] | None = None
    with tempfile.TemporaryDirectory(prefix="hyperdr-ncnn-") as temp:
        temporary = Path(temp)
        if source_onnx is None:
            candidate = checkpoint.resolve().parent.parent / "models" / "production-v3.features.onnx"
            if candidate.is_file():
                source_onnx = candidate
            else:
                source_onnx = temporary / "production-v3.features.onnx"
                onnx_metadata = _export_core_onnx(
                    checkpoint,
                    source_onnx,
                    height=height,
                    width=width,
                    dynamic=True,
                )
            source_manifest_file = _manifest_path(source_onnx)
            source_manifest_sha256 = _sha256(source_onnx)
            # ONNX is always the source of the checked-in ncnn artifact.  The
            # normal/reproducible path is the feature ONNX beside the frozen
            # checkpoint.
        else:
            source_onnx = source_onnx.resolve()
            if not source_onnx.is_file():
                raise SystemExit(f"--source-onnx does not exist: {source_onnx}")
            source_manifest_file = _manifest_path(source_onnx)
            source_manifest_sha256 = _sha256(source_onnx)
            # pnnx writes its intermediate *.pnnx.* files next to the input
            # model.  Copy a caller-provided source into the scratch folder so
            # conversion never pollutes or rewrites a checked-in ONNX asset.
        temporary_source = temporary / source_onnx.name
        if temporary_source.resolve() != source_onnx.resolve():
            shutil.copyfile(source_onnx, temporary_source)
        source_onnx = temporary_source
        temporary_param = temporary / OUTPUT_PARAM
        temporary_bin = temporary / OUTPUT_BIN
        if source_kind == "onnx" and (second_height is not None or second_width is not None):
            # pnnx's ONNX importer infers dynamic ncnn dimensions from the
            # symbolic graph.  Supplying inputshape2 here makes it demand a
            # second static ONNX input shape and fails for the checked-in
            # graph; TorchScript conversion is intentionally not the default.
            second_height = None
            second_width = None
        log = _run_pnnx(
            executable,
            source_onnx,
            temporary_param,
            temporary_bin,
            height=height,
            width=width,
            second_height=second_height,
            second_width=second_width,
        )
        if not temporary_param.is_file() or not temporary_bin.is_file():
            raise SystemExit("pnnx completed without producing both ncnn assets")
        input_blob, output_blob, layers = _check_param(temporary_param)
        # PNNX emits a pair atomically only after conversion succeeded.  Copy
        # both files only after all structural checks pass.
        shutil.copyfile(temporary_param, output_param)
        shutil.copyfile(temporary_bin, output_bin)

    manifest: dict[str, Any] = {
        "schema": "hyperdr.model-ncnn/v1",
        "converter": {
            "name": "pnnx",
            "path": executable.name,
            "version": CONVERTER_VERSION,
            "fp16": False,
            "optlevel": 2,
        },
        "checkpoint": {
            "file": str(checkpoint),
            "sha256": _sha256(checkpoint),
        },
        "source": {
            "kind": source_kind,
            "file": source_manifest_file,
            "sha256": source_manifest_sha256,
            **({"onnx": onnx_metadata.get("onnx", {})} if onnx_metadata else {}),
        },
        "graph": {
            "kind": "features",
            "input_blob": input_blob,
            "output_blob": output_blob,
            "input_shape": [1, 5, height, width],
            "output_shape": [1, 1, height // MODEL_STRIDE, width // MODEL_STRIDE],
            "second_input_shape": (
                [1, 5, second_height, second_width]
                if second_height is not None and second_width is not None
                else None
            ),
            "feature_contract": {
                "channels": ["linear_p3_r", "linear_p3_g", "linear_p3_b", "log_luminance", "clipping"],
                "layout": "BCHW",
                "linear_range": [0.0, 1.0],
                "luminance_coefficients": [0.22897456, 0.69173852, 0.07928691],
                "log_luminance": "clamp((log2(max(luminance, 1e-6)) + 12) / 12, 0, 1)",
                "clipping": "float(max(linear_p3, dim=channel) >= 0.98)",
            },
        },
        "assets": {
            "param": {
                "file": str(output_param),
                "sha256": _sha256(output_param),
                "size_bytes": output_param.stat().st_size,
            },
            "bin": {
                "file": str(output_bin),
                "sha256": _sha256(output_bin),
                "size_bytes": output_bin.stat().st_size,
            },
        },
        "layers": layers,
        "inference_only": True,
    }
    output_manifest.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    # Keep converter output available in CI logs without baking it into the
    # manifest (paths in pnnx's diagnostics are machine-specific).
    if os.environ.get("HYPERDR_NCNN_VERBOSE"):
        print(log)
    print(json.dumps(manifest, indent=2))
    return manifest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--pnnx", help="path to the pnnx executable")
    parser.add_argument("--source-onnx", type=Path, help="pre-exported five-channel core ONNX")
    parser.add_argument("--height", type=lambda value: _size(value, "--height"), default=DEFAULT_HEIGHT)
    parser.add_argument("--width", type=lambda value: _size(value, "--width"), default=DEFAULT_WIDTH)
    parser.add_argument("--second-height", type=lambda value: _size(value, "--second-height"))
    parser.add_argument("--second-width", type=lambda value: _size(value, "--second-width"))
    args = parser.parse_args(argv)
    if (args.second_height is None) != (args.second_width is None):
        parser.error("--second-height and --second-width must be supplied together")
    convert_ncnn(
        checkpoint=args.checkpoint,
        output_dir=args.output_dir,
        pnnx=args.pnnx,
        height=args.height,
        width=args.width,
        second_height=args.second_height,
        second_width=args.second_width,
        source_onnx=args.source_onnx,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
