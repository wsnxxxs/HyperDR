# HyperDR_Model integration

`HyperDR_Model` is connected as an optional inference stage in the local panel:

```text
input image
  -> HyperDR thumbnail (RAW/HEIC only)
  -> HyperDR_Model/infer_gain.py
  -> model-gain.f32 + model-gain.json
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

For direct CLI use, generate the pair first and then run:

```powershell
HyperDR convert photo.jpg --output out `
  --external-gain out\model-gain.f32 `
  --external-gain-report out\model-gain.json
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
