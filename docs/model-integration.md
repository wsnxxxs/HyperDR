# Native AI model integration

The panel's “AI 优化” action runs the production model inside `HyperDR.exe`.
There is no runtime Python environment, Python child process, checkpoint load,
or `.f32`/`.json` model sidecar.

```text
decoded linear Display-P3 image
  -> finished SDR: sample-preserving base
     scene RAW: automatic exposure + neutral development
  -> stride-16-aligned linear Display-P3 thumbnail
  -> embedded ncnn model
  -> raw signed log2 gain grid at thumbnail / 16
  -> gain controls once in signed-stop space
  -> ISO gain-map coding and lift once
  -> existing preview, reconstruction, and output encoders
```

The ncnn param and weights are compiled into the executable as Windows
resources. The package does not install loose model files or the PyTorch
checkpoint. `ncnn.dll` is shipped with the other runtime dependencies.

## Offline model export

Model export is a deliberate developer operation. The first graph is the
inference-only, three-channel ONNX exchange model:

```bash
PYTHONPATH=HyperDR_Model python HyperDR_Model/export_onnx.py \
  --checkpoint HyperDR_Model/checkpoints/production-v3.pt \
  --output HyperDR_Model/models/production-v3.onnx \
  --metadata HyperDR_Model/models/production-v3.onnx.json
```

The deployment frontend adds normalized log-luminance and clipping planes.
Export that five-plane view, then convert that ONNX graph to ncnn:

```bash
PYTHONPATH=HyperDR_Model python HyperDR_Model/export_onnx.py \
  --checkpoint HyperDR_Model/checkpoints/production-v3.pt \
  --graph features \
  --output HyperDR_Model/models/production-v3.features.onnx \
  --metadata HyperDR_Model/models/production-v3.features.onnx.json

PYTHONPATH=HyperDR_Model python HyperDR_Model/scripts/convert_ncnn.py \
  --checkpoint HyperDR_Model/checkpoints/production-v3.pt \
  --source-onnx HyperDR_Model/models/production-v3.features.onnx \
  --output-dir HyperDR_Model/models --pnnx pnnx
```

The converter is pinned to `pnnx==20260526`, rejects unsupported layers, and
records source and output hashes in `production-v3.ncnn.json`. The ncnn graph
uses blobs `in0` and `out0`; although conversion uses a reference shape, its
convolutional graph accepts stride-16-aligned spatial sizes and returns H/16 by
W/16.

Ordinary builds consume the checked-in assets. A deliberate refresh can use
`-DHYPERDR_REGENERATE_NCNN_MODEL=ON` with `HYPERDR_MODEL_PYTHON` and
`HYPERDR_PNNX_EXECUTABLE` configured.

## Runtime behavior

`HyperDR convert ... --ai-model embedded` and `preview-frame` use the same
in-memory path. JPEG, PNG, ordinary HEIC, and the base image of an Apple
gain-map container pass through as decoded linear Display-P3 SDR. Scene-linear
RAW keeps automatic exposure and highlight recovery, but uses a fixed neutral
development (`contrast=1`, `vibrance=0`, `pop=0`, exposure bias `0`). The
retained SDR base is the same image used to build the model tensor; there is no
8-bit intermediate or second tone render.

The default AI path does not guided-filter the prediction. Strength,
highlights, expansion start, and an optional HDR-range cap are applied directly
to the raw signed-stop grid, after which the grid is ISO-encoded and lifted
once. Identity post controls therefore preserve the model prediction instead
of decoding and re-quantizing it.

`HyperDR model-gain ... --ai-model embedded` is a diagnostic/panel probe. It
writes one binary `HYPGAIN1` packet to stdout containing JSON geometry followed
by the unfiltered stride-16 float32 signed-log2 ncnn prediction. It does not
apply strength or AI post controls and does not create sidecars.

The panel keeps its existing `useModel` / “AI 优化” interaction. In AI mode it
passes model strength plus these post-inference controls:

- brightness
- contrast
- shadows
- highlights
- HDR range
- expansion start

They are separate from the manual-mode controls. Manual look parameters do not
alter the tensor sent to the model, and stale AI values do not alter manual
mode.

`HYPERDR_MODEL_ENABLED=0` can hide/disable AI optimization by operator policy;
no other model runtime configuration is required.

## Model-domain limitation

The production model is trained from Apple-rendered ISO-native SDR, not a broad
corpus of generic camera RAW development. Camera colour, noise, highlight
recovery, and exposure distributions can therefore shift RAW predictions. RAW
remains a pure-model path with visual regression coverage on the repository's
samples; it is not presented as an HDR-ground-truth guarantee. Training,
evaluation, and legacy file-based research utilities remain under
`HyperDR_Model/`, but they are not part of the packaged panel runtime.
