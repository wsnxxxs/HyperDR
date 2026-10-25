#!/usr/bin/env python3
"""Convert a frozen HyperDR feature graph (ONNX) into a Core ML mlpackage.

The frozen deployment asset in ``models/`` is an ONNX graph that takes the five
deterministic feature planes (``in0``/``features``) and returns the stride-16
signed log2 gain grid. HyperDR embeds that graph through ncnn today; P7 runs the
same weights through Core ML on Mac, iPhone and iPad.

This script does not re-export from PyTorch. The deployed weights live in the
ONNX file (its sha256 is recorded in the model manifest), and feeding that file
through a translator keeps the Core ML model bit-for-bit the graph the shipped
ncnn model was produced from, instead of a second export of a checkpoint the
repository does not carry. The translator covers exactly the operator set
``convert_ncnn.py`` allows and fails closed on anything else.

    python3 HyperDR_Model/scripts/convert_coreml.py \
        --onnx HyperDR_Model/models/research-cnn-v1.features.onnx \
        --output HyperDR_Model/models/research-cnn-v1.mlpackage

Spatial dimensions stay flexible (stride-16 multiples) because the native
runtime resizes the SDR base to a caller-chosen long side, and the network's
group normalisation makes the result depend on that grid. A fixed export would
change the prediction for every photograph that is not exactly that size.

Verification, when onnxruntime is importable: the converted model is run on
several grid sizes and compared with the ONNX graph (fp32) it was made from.
That check is about the translation, not about deployment; the ncnn/Xcode side
of the tolerance gate lives in ``HyperDRRender``'s tests.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

import numpy as np
import onnx
from onnx import numpy_helper

import coremltools as ct
from coremltools.converters.mil import Builder as mb
from coremltools.converters.mil.mil.program import Symbol

MODEL_STRIDE = 16
DEFAULT_HEIGHT = 192
DEFAULT_WIDTH = 256
MAX_SPATIAL = 4096

# The operator set the frozen graph is allowed to use. Everything here has a
# direct MIL spelling; a new operator means a deliberate decision about its
# Core ML lowering, not a silent fallback.
ALLOWED_OPS = {
    "Conv",
    "Reshape",
    "InstanceNormalization",
    "Shape",
    "Mul",
    "Add",
    "Sigmoid",
    "AveragePool",
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def hw_pads(node: onnx.NodeProto) -> list[int]:
    """ONNX stores pads as [x1_begin, x2_begin, x1_end, x2_end] = T, L, B, R."""
    for attribute in node.attribute:
        if attribute.name == "pads":
            values = list(attribute.ints)
            if len(values) != 4:
                raise ValueError(f"{node.op_type}: expected 4 pads, got {values}")
            top, left, bottom, right = values
            return [top, bottom, left, right]
    return [0, 0, 0, 0]


def ints(node: onnx.NodeProto, name: str, default: list[int]) -> list[int]:
    for attribute in node.attribute:
        if attribute.name == name:
            return list(attribute.ints)
    return default


def integer(node: onnx.NodeProto, name: str, default: int) -> int:
    for attribute in node.attribute:
        if attribute.name == name:
            return int(attribute.i)
    return default


def number(node: onnx.NodeProto, name: str, default: float) -> float:
    for attribute in node.attribute:
        if attribute.name == name:
            return float(attribute.f)
    return default


def translate(graph: onnx.GraphProto, input_name: str, output_name: str,
              spatial: tuple[Any, Any]) -> Any:
    """Build a MIL program that computes the ONNX graph over one input.

    ``mb.TensorSpec`` takes its input name from the program's argument, and a
    spatial dimension is flexible when it is a ``Symbol``. The concrete bounds
    are attached by ``ct.convert(inputs=...)``; a flexible extent is required
    because the native runtime picks the analysis grid from the photo's size and
    the network's group normalisation depends on it.
    """
    shape = (1, 5, spatial[0], spatial[1])
    constants = {init.name: numpy_helper.to_array(init) for init in graph.initializer}
    values: dict[str, Any] = {}

    def operand(name: str) -> Any:
        if name in values:
            return values[name]
        if name in constants:
            return constants[name]
        raise KeyError(f"graph input {name!r} is neither computed nor constant")

    @mb.program(input_specs=[mb.TensorSpec(shape=shape)], opset_version=ct.target.iOS18)
    def program(features):  # noqa: ANN001 - MIL program function signature
        values[input_name] = features
        for node in graph.node:
            if node.op_type not in ALLOWED_OPS:
                raise ValueError(f"unsupported operator {node.op_type}; extend ALLOWED_OPS deliberately")
            inputs = [operand(name) for name in node.input]
            result: Any
            if node.op_type == "Conv":
                attributes: dict[str, Any] = {
                    "strides": ints(node, "strides", [1, 1]),
                    "dilations": ints(node, "dilations", [1, 1]),
                    "groups": integer(node, "group", 1),
                    "pad_type": "custom",
                    "pad": hw_pads(node),
                }
                if len(inputs) > 2:
                    attributes["bias"] = inputs[2]
                result = mb.conv(x=inputs[0], weight=inputs[1], **attributes)
            elif node.op_type == "InstanceNormalization":
                result = mb.instance_norm(x=inputs[0], gamma=inputs[1], beta=inputs[2],
                                          epsilon=number(node, "epsilon", 1e-5))
            elif node.op_type == "Reshape":
                # The first reshape carries [0, groups, -1]; the second one takes
                # the pre-normalisation shape back from Shape(conv). ONNX reads a
                # 0 as "copy this dimension of the input", which MIL's reshape
                # does not support, so the zero is turned into a slice of the
                # input's own shape. Keeping it symbolic (rather than baking in
                # the batch size) is what lets the spatial extent stay flexible.
                target = inputs[1]
                if isinstance(target, np.ndarray):
                    target = np.asarray(target, dtype=np.int32)
                    if np.any(target == 0):
                        dims = mb.shape(x=inputs[0])
                        pieces = [
                            mb.slice_by_index(x=dims, begin=[index], end=[index + 1])
                            if value == 0 else
                            mb.const(val=np.array([value], dtype=np.int32))
                            for index, value in enumerate(target)
                        ]
                        target = mb.concat(values=pieces, axis=0)
                result = mb.reshape(x=inputs[0], shape=target)
            elif node.op_type == "Shape":
                result = mb.shape(x=inputs[0])
            elif node.op_type == "AveragePool":
                result = mb.avg_pool(
                    x=inputs[0],
                    kernel_sizes=ints(node, "kernel_shape", [2, 2]),
                    strides=ints(node, "strides", [1, 1]),
                    pad_type="custom",
                    pad=hw_pads(node),
                    ceil_mode=integer(node, "ceil_mode", 0) == 1)
            elif node.op_type == "Sigmoid":
                result = mb.sigmoid(x=inputs[0])
            elif node.op_type == "Mul":
                result = mb.mul(x=inputs[0], y=inputs[1])
            elif node.op_type == "Add":
                result = mb.add(x=inputs[0], y=inputs[1])
            else:  # pragma: no cover - ALLOWED_OPS is exhaustive above
                raise AssertionError(node.op_type)
            values[node.output[0]] = result
        return mb.identity(x=values[output_name], name=output_name)

    return program


def onnx_reference(onnx_path: Path, tensor: np.ndarray) -> np.ndarray:
    import onnxruntime as ort

    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    return session.run(None, {name: tensor})[0]


def feature_planes(rng: np.random.Generator, height: int, width: int) -> np.ndarray:
    """A random but plausible five-plane tensor in the deployed contract."""
    linear = rng.random((1, 3, height, width), dtype=np.float32) ** 2.2
    luminance = (0.22897456 * linear[:, 0:1] + 0.69173852 * linear[:, 1:2]
                 + 0.07928691 * linear[:, 2:3])
    log_luminance = np.clip((np.log2(np.maximum(luminance, 1e-6)) + 12.0) / 12.0, 0.0, 1.0)
    clipping = (linear.max(axis=1, keepdims=True) >= 0.98).astype(np.float32)
    return np.concatenate((linear, log_luminance, clipping), axis=1).astype(np.float32)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--onnx", type=Path, default=Path("HyperDR_Model/models/research-cnn-v1.features.onnx"))
    parser.add_argument("--output", type=Path, default=Path("HyperDR_Model/models/research-cnn-v1.mlpackage"))
    parser.add_argument("--manifest", type=Path, default=None,
                        help="conversion manifest (default: <model>.coreml.json beside the mlpackage)")
    parser.add_argument("--install", type=Path, default=None,
                        help="also copy the mlpackage into this directory (the Swift package resource)")
    parser.add_argument("--model-id", default="research-cnn-v1")
    parser.add_argument("--version", default="research-demo-fold0-seed908/v1")
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT,
                        help="default analysis height; the spatial extent stays flexible")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH)
    parser.add_argument("--fixed", action="store_true",
                        help="export one fixed grid instead of a flexible spatial extent")
    parser.add_argument("--precision", choices=("float16", "float32"), default="float16")
    parser.add_argument("--skip-verify", action="store_true")
    args = parser.parse_args(argv)

    onnx_model = onnx.load(str(args.onnx))
    graph = onnx_model.graph
    input_name = graph.input[0].name
    output_name = graph.output[0].name
    operators = sorted({node.op_type for node in graph.node})
    unknown = [op for op in operators if op not in ALLOWED_OPS]
    if unknown:
        raise SystemExit(f"graph uses operators without a MIL translation: {unknown}")

    for edge in (args.height, args.width):
        if edge % MODEL_STRIDE:
            raise SystemExit("default analysis extent must be a multiple of the 16-pixel stride")
    if args.fixed:
        spatial: tuple[Any, Any] = (args.height, args.width)
        shape: list[Any] = [1, 5, args.height, args.width]
    else:
        spatial = (Symbol("H"), Symbol("W"))
        shape = [1, 5,
                 ct.RangeDim(lower_bound=MODEL_STRIDE, upper_bound=MAX_SPATIAL,
                             default=args.height),
                 ct.RangeDim(lower_bound=MODEL_STRIDE, upper_bound=MAX_SPATIAL,
                             default=args.width)]

    program = translate(graph, input_name, output_name, spatial)
    precision = ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32
    model = ct.convert(program, convert_to="mlprogram", compute_precision=precision,
                       minimum_deployment_target=ct.target.iOS18,
                       inputs=[ct.TensorType(name=input_name, dtype=np.float32, shape=shape)])
    declared_input = model.get_spec().description.input[0].name

    model.short_description = ("HyperDR AI gain: five linear Display-P3 feature planes in, "
                               "signed log2 gain in stops out, on a stride-16 grid.")
    model.author = "HyperDR"
    model.user_defined_metadata.update({
        "hyperdr.modelId": args.model_id,
        "hyperdr.modelVersion": args.version,
        "hyperdr.inputContract": (
            "BCHW float32, 5 channels: linear Display-P3 R,G,B in [0,1]; "
            "log luminance clamp((log2(max(luma,1e-6))+12)/12, 0, 1) with "
            "luma = 0.22897456 R + 0.69173852 G + 0.07928691 B; "
            "clipping = max(R,G,B) >= 0.98"),
        "hyperdr.outputContract": "single-channel signed log2 gain in stops, stride 16",
        "hyperdr.gridAlignment": f"multiples of {MODEL_STRIDE}",
        "hyperdr.sourceOnnxSha256": sha256_file(args.onnx),
    })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.output.exists():
        import shutil
        shutil.rmtree(args.output)
    model.save(str(args.output))
    weights = args.output / "Data/com.apple.CoreML/weights/weight.bin"
    weights_sha256 = sha256_file(weights) if weights.exists() else ""
    installed: str | None = None
    if args.install is not None:
        import shutil
        target = args.install / args.output.name
        if target.resolve() != args.output.resolve():
            args.install.mkdir(parents=True, exist_ok=True)
            if target.exists():
                shutil.rmtree(target)
            shutil.copytree(args.output, target)
            installed = str(target)
            print(f"installed {target}", file=sys.stderr)

    checks: list[dict[str, Any]] = []
    if not args.skip_verify:
        rng = np.random.default_rng(20261021)
        candidates = [(args.height, args.width), (96, 144), (512, 512), (688, 1024)]
        if args.fixed:
            candidates = [(args.height, args.width)]
        for height, width in candidates:
            tensor = feature_planes(rng, height, width)
            expected = onnx_reference(args.onnx, tensor)
            # The request API wants the input name the mlpackage declares.
            produced = model.predict({declared_input: tensor})[output_name]
            produced = np.asarray(produced, dtype=np.float32).reshape(expected.shape)
            difference = np.abs(produced - expected)
            checks.append({
                "grid": [height // MODEL_STRIDE, width // MODEL_STRIDE],
                "tensor": [height, width],
                "maxAbsStops": float(difference.max()),
                "meanAbsStops": float(difference.mean()),
                "gainMaxStops": float(expected.max()),
            })
        worst = max(check["maxAbsStops"] for check in checks)
        print(f"translation check: worst |Core ML - ONNX| = {worst:.6f} stops", file=sys.stderr)

    weights = sorted(args.output.rglob("*"))
    size = sum(path.stat().st_size for path in weights if path.is_file())
    manifest = {
        "schema": "hyperdr.coreml-model/v1",
        "modelId": args.model_id,
        "version": args.version,
        "source": {
            "onnx": str(args.onnx),
            "sha256": sha256_file(args.onnx),
        },
        "operators": operators,
        "input": {
            "name": declared_input,
            "shape": ["1", "5", args.height if args.fixed else f"{MODEL_STRIDE}..{MAX_SPATIAL} (x{args.height})",
                      args.width if args.fixed else f"{MODEL_STRIDE}..{MAX_SPATIAL} (x{args.width})"],
            "stride": MODEL_STRIDE,
        },
        "output": {"name": output_name, "scale": "signed-log2-gain", "unit": "stops"},
        "computePrecision": args.precision,
        "minimumDeploymentTarget": "iOS18/macOS15",
        "mlpackageBytes": size,
        "weightsSha256": weights_sha256,
        "installed": installed,
        "translationChecks": checks,
        "tool": {
            "coremltools": ct.__version__,
            "onnx": onnx.__version__,
            "numpy": np.__version__,
        },
    }
    manifest_path = args.manifest or args.output.with_name(args.output.stem + ".coreml.json")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"wrote {args.output} ({size / 1e6:.2f} MB) and {manifest_path}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
