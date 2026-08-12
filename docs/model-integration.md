# HyperDR_Model integration

`HyperDR_Model` is an optional inference stage in the local panel. The normal
HyperDR path stays the default even when the model runtime is enabled: in the
panel, inference starts only when the user clicks “优化”, and the `.f32` grid it
produces then drives both the live preview and the next conversion. Importing or
replacing an image returns to the mathematical preview.

```text
input image
  -> HyperDR photographic SDR development
     (RAW uses LibRaw half-size; auto exposure + photographic-v1 tone/look)
  -> stride-16 linear Display P3 HWC float32
  -> HyperDR_Model/infer_gain.py
  -> model-gain.f32 + bound model-gain.json
  -> full-resolution decode + replay the frozen development recipe
  -> replace only the mathematical Gain Map
  -> HyperDR --external-gain ...
  -> HDR output
```

The repository includes a Windows runtime under `HyperDR_Model/`: the trained
checkpoint, inference code, a Windows virtual environment, and the Display P3
profile needed by inference. The full private training dataset stays in WSL;
panel inference does not need it. The model project also provides a dataset root
whose `assets/display-p3.icc` was built by its cache workflow.

## Runtime configuration on Windows

The bundled runtime is detected automatically; the production v3 checkpoint and
its JSON release manifest are found without any configuration. The overrides
below exist for trying a different checkpoint or installation:

```powershell
$env:HYPERDR_MODEL_ENABLED = "1"
$env:HYPERDR_MODEL_ROOT = "<path to HyperDR_Model>"
$env:HYPERDR_MODEL_CHECKPOINT = "<checkpoint.pt>"
$env:HYPERDR_MODEL_DATASET_ROOT = "<dataset root>"
$env:HYPERDR_MODEL_PYTHON = "<python.exe inside the model venv>"
$env:HYPERDR_MODEL_DEVICE = "auto"
python apps\panel\hyperdr_gui.py
```

To reproduce the retired normalized-v1 path with `best.pt`, set both
`HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA=1` and
`HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN=1`.

## How a model run works

The panel reports model readiness through `/api/state`. An optimized run logs
the model subprocess, writes intermediate files under the session's hidden
`.model` directory, and passes the validated pair to HyperDR. If the model
fails, the conversion stops before an output file is written.

There is no sRGB JPEG in between. `HyperDR model-input` develops the SDR base
first, resamples it with the native area-then-bilinear convention, and writes
little-endian HWC float32 linear Display P3 straight to PyTorch, keeping P3
colours intact and skipping JPEG quantisation. For RAW, preparation uses
LibRaw's fixed half-size demosaic, and the chosen exposure plus the full
photographic recipe are written down once and replayed during the later
full-size export instead of being estimated again. Model preparation and
ordinary RAW previews share one process-wide RAW memory admission pool.

The gain report carries a `hyperdr.model-gain-binding/v1` record so HyperDR can
tell whether a grid still matches the photo it was computed for: source hash,
highlight recovery, sensor raster, requested and delivered crop, orientation,
developed/tensor/grid sizes, resize convention, and the model version and
checkpoint hash. If any current source or decode property disagrees, the
conversion stops rather than rendering from a stale grid.

For direct CLI use, generate the direct-float input and its report first, then
run:

```powershell
HyperDR model-input photo.ARW --output out\model-input.f32 `
  --report out\model-input.json --long-side 1024 --half-size
python HyperDR_Model\infer_gain.py --input out\model-input.f32 `
  --input-report out\model-input.json `
  --checkpoint HyperDR_Model\checkpoints\production-v3.pt `
  --gain-output out\model-gain.f32 --report out\model-gain.json `
  --dataset-root HyperDR_Model\dataset
HyperDR convert photo.ARW --output out `
  --external-gain out\model-gain.f32 `
  --external-gain-report out\model-gain.json
```

## Gain-map labels

Phase A v2 sidecars declare `label_contract_id=hyperdr.apple-gain-label/v2` and
store signed canonical `log2(linear gain)` with exact ISO rationals. The
converter accepts frozen v1 normalized sidecars only with
`--allow-legacy-external-gain`; the panel mirrors that gate with
`HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN=1`. The label contract itself is documented
once, in [HyperDR_Model/README.md](../HyperDR_Model/README.md).

When the input is an Apple gain-map HEIC, an external v2 grid selects the
embedded SDR base item instead of applying the embedded gain first, so the
source map is not counted twice before the model grid is encoded.

## Experimental RAW model limitations

The production v3 checkpoint was trained from Apple-rendered ISO-native SDR
rather than generic camera RAW, so camera colour, noise and exposure
distributions can shift its predictions. Its direct head emits raw signed log2
gain and the inference stage writes native v2 sidecars, but the network still
does not consume ISO, shutter, aperture or camera-model metadata; per-image ISO
metadata is conservatively derived from the prediction. LibRaw highlight
recovery is not Apple's SDR/HDR processing. The unified base and binding
contract removed the earlier reference-image error. These model-domain
limitations remain, and quality is not uniform across cameras.
