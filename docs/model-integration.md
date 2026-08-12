# HyperDR_Model integration

`HyperDR_Model` is connected as an optional inference stage in the local panel:

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

The normal HyperDR path remains the default even when the model runtime is
enabled. In the panel, inference starts only when the user clicks “优化”; the
generated `.f32` grid then drives both the live preview and the next conversion.
Importing or replacing an image returns to the mathematical preview. The model
project is expected to provide a trained checkpoint and a dataset root whose
`assets/display-p3.icc` file was built by its cache workflow.

## Model runtime on Windows

The bundled runtime is detected automatically. The following overrides remain
available when using a different checkpoint or installation:

```powershell
$env:HYPERDR_MODEL_ENABLED = "1"
$env:HYPERDR_MODEL_ROOT = "C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model"
$env:HYPERDR_MODEL_CHECKPOINT = "C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model\checkpoints\best.pt"
$env:HYPERDR_MODEL_DATASET_ROOT = "C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model\dataset"
$env:HYPERDR_MODEL_PYTHON = "C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model\.venv\Scripts\python.exe"
$env:HYPERDR_MODEL_DEVICE = "auto"
# Existing checkpoints are frozen v1 normalized labels. Explicitly opt in only
# when reproducing that contract; native ISO v2 checkpoints do not need this.
$env:HYPERDR_MODEL_ALLOW_LEGACY_LABEL_SCHEMA = "1"
$env:HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN = "1"
python apps\panel\hyperdr_gui.py
```

The model legacy variable is also honored by the panel's HyperDR command
builder, so an explicit v1 opt-in reaches both subprocesses; the separate
external-gain variable remains available for direct sidecar-only workflows.

The repository now includes a Windows runtime at
`C:\Users\Ryan\Desktop\HyperDR\HyperDR_Model`, containing the trained
checkpoint, inference code, Windows virtual environment, and the Display P3
profile needed by inference. The full private training dataset remains in WSL;
it is not needed for panel inference.

The panel exposes model readiness through `/api/state`. An optimized run logs
the model subprocess, writes intermediate files under the session's hidden
`.model` directory, and passes the validated pair to HyperDR. A model failure
stops the conversion before an output file is written.

There is no sRGB JPEG intermediary. `HyperDR model-input` develops the SDR base
first, resamples that base using the native area-then-bilinear convention, and
writes little-endian HWC float32 linear Display P3 directly for PyTorch. This
preserves P3 colours and avoids JPEG quantisation. RAW model preparation uses
LibRaw's fixed half-size demosaic; the chosen exposure and full photographic
recipe are written once and replayed during the later full-size export instead
of being estimated again.

The gain report carries `hyperdr.model-gain-binding/v1`: source SHA-256,
highlight recovery, sensor raster, requested and delivered crop, orientation,
developed/tensor/grid sizes, resize convention, model version and checkpoint
SHA-256. HyperDR rejects a stale grid before rendering if any current source or
decode property disagrees. Model preparation and ordinary RAW previews also use
one shared process-wide RAW memory admission pool.

For direct CLI use, generate the direct-float input and pair first, then run:

```powershell
HyperDR model-input photo.ARW --output out\model-input.f32 `
  --report out\model-input.json --long-side 1024 --half-size
python HyperDR_Model\infer_gain.py --input out\model-input.f32 `
  --input-report out\model-input.json --checkpoint checkpoints\best.pt `
  --gain-output out\model-gain.f32 --report out\model-gain.json `
  --dataset-root dataset --allow-legacy-label-schema
HyperDR convert photo.ARW --output out `
  --external-gain out\model-gain.f32 `
  --external-gain-report out\model-gain.json `
  --allow-legacy-external-gain
```

Phase A v2 sidecars declare `label_contract_id=hyperdr.apple-gain-label/v2`
and store signed canonical `log2(linear gain)` together with exact ISO
rationals. The converter accepts frozen v1 normalized sidecars only when
`--allow-legacy-external-gain` is supplied; the panel mirrors that gate with
`HYPERDR_ALLOW_LEGACY_EXTERNAL_GAIN=1`.

When the input itself is an Apple gain-map HEIC, an external v2 grid selects
the embedded SDR base item instead of applying the embedded gain first. This
prevents the source map from being double-counted before the model grid is
encoded.

## Experimental RAW model limitations

The current checkpoint was trained from Apple-rendered SDR rather than generic
camera RAW. Camera colour, noise and exposure distributions can therefore shift
predictions. The frozen v1 head predicts only normalized positive gain in the
fixed 0–3 stop range; it cannot emit negative gain or native signed ISO v2, and
it does not consume ISO, shutter, aperture or camera-model metadata. LibRaw
highlight recovery is not Apple's SDR/HDR processing. The unified base and
binding contract remove the previous reference-image error, but they do not
remove these model-domain limitations or make quality uniform across cameras.
