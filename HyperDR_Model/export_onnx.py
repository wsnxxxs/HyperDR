#!/usr/bin/env python3
"""Export the frozen Direct-v3 checkpoint as inference-only ONNX.

The training checkpoint contains an optimizer, scheduler and RNG snapshots in
addition to the model parameters.  None of those objects belong in a runtime
artifact.  This exporter intentionally reconstructs the model from the
checkpoint configuration and gives ``torch.onnx`` only the frozen module.

Two graphs are available:

``direct`` (the default)
    The public model contract.  It accepts BCHW linear Display-P3 with three
    channels and emits signed log2 gain stops.

``features``
    The same network after its five-channel feature construction.  ncnn does
    not have a portable comparison/reduction implementation for the clipping
    feature on every supported release, so the native runtime computes the
    three-channel linear, log-luminance and clipping planes and feeds this
    graph.  The weights are identical to the direct graph; this is not a
    second model or a re-trained approximation.

The feature graph is useful for ncnn conversion, while the direct graph is
the interchange artifact that should be used by ONNX runtimes.  ncnn model
conversion is kept in ``scripts/convert_ncnn.py`` so that conversion tools are
never silently substituted with made-up weights.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sys
from typing import Any

import torch
from torch import nn
import torch.nn.functional as F

from hyperdr_ml.model import DirectGainMapNet, MODEL_STRIDE
from hyperdr_ml.phase_a_labels import LABEL_CONTRACT_ID


EXPORT_SCHEMA = "hyperdr.model-onnx/v1"
FEATURE_INPUT_CHANNELS = 5
DEFAULT_HEIGHT = 192
DEFAULT_WIDTH = 256
DEFAULT_OPSET = 18


class FeatureGainMapNet(nn.Module):
    """Expose DirectGainMapNet after its deterministic five-plane frontend."""

    def __init__(self, model: DirectGainMapNet) -> None:
        super().__init__()
        self.model = model

    def forward(self, features: torch.Tensor) -> torch.Tensor:
        if features.ndim != 4 or features.shape[1] != FEATURE_INPUT_CHANNELS:
            raise ValueError(
                "FeatureGainMapNet expects BCHW five-channel features, got "
                f"{tuple(features.shape)}"
            )
        x1 = self.model.stem(features)
        x2 = self.model.stage2(x1)
        x3 = self.model.stage3(x2)
        x4 = self.model.stage4(x3)
        x4 = self.model.context(x4)
        # Inputs are stride-16 aligned, so x3 is exactly twice x4 in both
        # spatial dimensions.  ``ceil_mode`` makes that relationship
        # expressible to torch.export for symbolic dimensions while remaining
        # bit-equivalent to the original adaptive pool on the validated
        # aligned input domain.  It also removes Shape/Reshape plumbing that
        # older pnnx releases cannot lower.
        skip = F.avg_pool2d(x3, kernel_size=2, stride=2, ceil_mode=True)
        x4 = x4 + self.model.skip3(skip)
        return self.model.head(x4)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _parse_size(value: str, name: str) -> int:
    try:
        parsed = int(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError(f"{name} must be an integer") from exc
    if parsed < MODEL_STRIDE or parsed % MODEL_STRIDE:
        raise argparse.ArgumentTypeError(
            f"{name} must be a positive multiple of {MODEL_STRIDE}"
        )
    return parsed


def _load_model(checkpoint_path: Path) -> tuple[DirectGainMapNet, dict[str, Any], dict[str, Any]]:
    if not checkpoint_path.is_file():
        raise SystemExit(f"checkpoint does not exist: {checkpoint_path}")
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=False)
    if not isinstance(checkpoint, dict):
        raise SystemExit("checkpoint is not a mapping")
    config = checkpoint.get("config")
    if not isinstance(config, dict):
        raise SystemExit("checkpoint has no model config")
    contract = checkpoint.get("label_contract_id")
    if contract != LABEL_CONTRACT_ID:
        raise SystemExit(
            "ONNX export only accepts the signed v2 checkpoint contract "
            f"({LABEL_CONTRACT_ID}); got {contract!r}"
        )
    if config.get("model") != "direct" or config.get("target_mode") != "signed_stops":
        raise SystemExit(
            "ONNX export requires a direct signed-stops checkpoint; "
            f"got model={config.get('model')!r}, target_mode={config.get('target_mode')!r}"
        )
    architecture = config.get("architecture", "baseline")
    if architecture != "baseline":
        raise SystemExit(
            "The fixed ncnn/ONNX runtime currently accepts only the production "
            f"baseline architecture; got {architecture!r}"
        )
    try:
        base_channels = int(config["base_channels"])
    except (KeyError, TypeError, ValueError) as exc:
        raise SystemExit("checkpoint config has no valid base_channels") from exc
    model = DirectGainMapNet(base_channels, architecture, "signed_stops_v2")
    try:
        model.load_state_dict(checkpoint["model"], strict=True)
    except (KeyError, RuntimeError, TypeError) as exc:
        raise SystemExit(f"checkpoint model weights do not match DirectGainMapNet: {exc}") from exc
    model.eval()
    model.requires_grad_(False)
    return model, config, checkpoint


def _export_graph(
    graph: nn.Module,
    output: Path,
    *,
    input_name: str,
    output_name: str,
    height: int,
    width: int,
    batch: int,
    opset: int,
    dynamic: bool,
) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    example = torch.zeros(batch, 3 if input_name == "linear_p3" else FEATURE_INPUT_CHANNELS, height, width)
    dynamic_shapes = None
    dynamic_axes = None
    if dynamic:
        # torch.export (the current torch.onnx exporter) requires the dynamic
        # shape map to use the actual forward argument name.
        dynamic_shapes = {
            input_name: {0: "batch", 2: "height", 3: "width"},
        }
        dynamic_axes = {
            input_name: {0: "batch", 2: "height", 3: "width"},
            output_name: {0: "batch", 2: "gain_height", 3: "gain_width"},
        }

    # ``dynamo=True`` is required for dynamic output shapes because the legacy
    # exporter cannot lower adaptive_avg_pool2d with a symbolic size.  The
    # fallback keeps this script useful with older torch releases for static
    # exports, while still failing loudly for an unsupported dynamic request.
    try:
        torch.onnx.export(
            graph,
            (example,),
            str(output),
            input_names=[input_name],
            output_names=[output_name],
            opset_version=opset,
            dynamo=True,
            external_data=False,
            dynamic_shapes=dynamic_shapes,
            dynamic_axes=dynamic_axes,
            export_params=True,
            keep_initializers_as_inputs=False,
            training=torch.onnx.TrainingMode.EVAL,
            do_constant_folding=True,
        )
    except (TypeError, ModuleNotFoundError, ImportError) as exc:
        # Older torch versions do not know ``dynamo``/``external_data`` or do
        # not carry onnxscript.  Static legacy export remains valid; dynamic
        # export must use a modern exporter and therefore reports the missing
        # dependency instead of writing a misleading static artifact.
        if dynamic:
            raise SystemExit(
                "dynamic ONNX export needs torch>=2.6 with onnxscript and onnx; "
                f"export failed: {exc}"
            ) from exc
        try:
            torch.onnx.export(
                graph,
                (example,),
                str(output),
                input_names=[input_name],
                output_names=[output_name],
                opset_version=opset,
                dynamo=False,
                export_params=True,
                keep_initializers_as_inputs=False,
                training=torch.onnx.TrainingMode.EVAL,
                do_constant_folding=True,
            )
        except Exception as legacy_exc:
            raise SystemExit(f"ONNX export failed: {legacy_exc}") from legacy_exc

    if not output.is_file() or output.stat().st_size == 0:
        raise SystemExit(f"torch.onnx did not produce a non-empty file: {output}")


def _check_onnx(path: Path, *, input_name: str, dynamic: bool) -> None:
    try:
        import onnx  # type: ignore
    except ImportError as exc:
        raise SystemExit(
            "onnx is required to validate the exported graph; install it with "
            "`python -m pip install onnx onnxscript`"
        ) from exc
    model = onnx.load(str(path), load_external_data=False)
    onnx.checker.check_model(model)
    graph_inputs = {value.name: value for value in model.graph.input}
    graph_outputs = {value.name: value for value in model.graph.output}
    if input_name not in graph_inputs or "gain_stops" not in graph_outputs:
        raise SystemExit("ONNX graph does not expose the declared input/output names")
    if dynamic:
        for name, value in (
            (input_name, graph_inputs[input_name]),
            ("gain_stops", graph_outputs["gain_stops"]),
        ):
            dimensions = value.type.tensor_type.shape.dim
            for axis in (0, 2, 3):
                if not dimensions[axis].dim_param:
                    raise SystemExit(
                        f"dynamic ONNX contract violated: {name} axis {axis} is fixed"
                    )


def _metadata(
    *,
    checkpoint: Path,
    config: dict[str, Any],
    checkpoint_payload: dict[str, Any],
    output: Path,
    graph_kind: str,
    input_name: str,
    input_channels: int,
    height: int,
    width: int,
    batch: int,
    opset: int,
    dynamic: bool,
) -> dict[str, Any]:
    return {
        "schema": EXPORT_SCHEMA,
        "model_id": str(config.get("model_id") or "hyperdr.direct-fixed-incumbent/v3-production"),
        "graph": graph_kind,
        "checkpoint": {
            "file": str(checkpoint),
            "sha256": _sha256(checkpoint),
            "epoch": checkpoint_payload.get("epoch"),
            "label_contract_id": checkpoint_payload.get("label_contract_id"),
        },
        "model": {
            "family": "DirectGainMapNet",
            "architecture": config.get("architecture", "baseline"),
            "base_channels": int(config["base_channels"]),
            "parameters": sum(p.numel() for p in DirectGainMapNet(
                int(config["base_channels"]), config.get("architecture", "baseline"), "signed_stops_v2"
            ).parameters()),
            "input": (
                "linear Display-P3 SDR, BCHW, three channels"
                if graph_kind == "direct"
                else "DirectGainMapNet feature planes, BCHW, five channels"
            ),
            "output": "single-channel raw signed log2 gain in stops",
            "target_mode": "signed_stops",
        },
        "onnx": {
            "file": str(output),
            "sha256": _sha256(output),
            "opset": opset,
            "input_name": input_name,
            "output_name": "gain_stops",
            "input_shape": [batch, input_channels, height, width],
            "output_shape": [batch, 1, height // MODEL_STRIDE, width // MODEL_STRIDE],
            "dynamic_spatial": dynamic,
            "external_data": False,
            "inference_only": True,
        },
    }


def export_onnx(
    *,
    checkpoint: Path,
    output: Path,
    graph_kind: str,
    height: int,
    width: int,
    batch: int,
    opset: int,
    dynamic: bool,
    metadata_path: Path | None,
) -> dict[str, Any]:
    model, config, checkpoint_payload = _load_model(checkpoint)
    if graph_kind == "direct":
        graph: nn.Module = model
        input_name = "linear_p3"
        input_channels = 3
    elif graph_kind == "features":
        graph = FeatureGainMapNet(model)
        input_name = "features"
        input_channels = FEATURE_INPUT_CHANNELS
    else:
        raise SystemExit(f"unknown graph kind: {graph_kind!r}")
    graph.eval()
    graph.requires_grad_(False)
    _export_graph(
        graph,
        output,
        input_name=input_name,
        output_name="gain_stops",
        height=height,
        width=width,
        batch=batch,
        opset=opset,
        dynamic=dynamic,
    )
    _check_onnx(output, input_name=input_name, dynamic=dynamic)
    metadata = _metadata(
        checkpoint=checkpoint,
        config=config,
        checkpoint_payload=checkpoint_payload,
        output=output,
        graph_kind=graph_kind,
        input_name=input_name,
        input_channels=input_channels,
        height=height,
        width=width,
        batch=batch,
        opset=opset,
        dynamic=dynamic,
    )
    if metadata_path is not None:
        metadata_path.parent.mkdir(parents=True, exist_ok=True)
        metadata_path.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    return metadata


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--graph",
        choices=("direct", "features"),
        default="direct",
        help="direct is the public 3-channel graph; features is the ncnn core graph",
    )
    parser.add_argument("--metadata", type=Path)
    parser.add_argument("--height", type=lambda value: _parse_size(value, "--height"), default=DEFAULT_HEIGHT)
    parser.add_argument("--width", type=lambda value: _parse_size(value, "--width"), default=DEFAULT_WIDTH)
    parser.add_argument("--batch", type=int, default=1)
    parser.add_argument("--opset", type=int, default=DEFAULT_OPSET)
    parser.add_argument(
        "--static",
        action="store_true",
        help="keep direct-graph dimensions fixed; feature graphs must remain dynamic",
    )
    args = parser.parse_args(argv)
    if args.graph == "features" and args.static:
        parser.error(
            "feature ONNX H/W must remain dynamic; pass the fixed pnnx conversion "
            "shape to scripts/convert_ncnn.py instead"
        )
    if args.batch <= 0:
        parser.error("--batch must be positive")
    if args.opset < 18:
        parser.error("--opset must be at least 18 for the dynamo exporter")
    metadata = export_onnx(
        checkpoint=args.checkpoint,
        output=args.output,
        graph_kind=args.graph,
        height=args.height,
        width=args.width,
        batch=args.batch,
        opset=args.opset,
        dynamic=not args.static,
        metadata_path=args.metadata,
    )
    print(json.dumps(metadata, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
