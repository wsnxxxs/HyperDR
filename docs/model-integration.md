# Native AI model integration

The panel's “AI 优化” action runs one of two embedded models inside
`HyperDR.exe`. There is no runtime Python environment, Python child process,
checkpoint load, or `.f32`/`.json` model sidecar.

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

The checked-in CNN and EXIF-assisted assets are generated offline with
`HyperDR_Model/scripts/export_research_assets.py`, which reuses the ONNX export
and ncnn conversion tools. Ordinary builds embed those two param/bin pairs;
the retired production model assets and build-time regeneration path are removed.
Historical training checkpoints remain outside the application build.

## Selectable models

`--ai-model` takes an id from a fixed table, not a path: the shipping adapter
owns the assets and never opens a caller-named file. `embedded` and an omitted
value select CNN. Unsupported IDs are errors. The panel restores old saved
model selections as CNN and never offers the retired production model.

| id | Shown as | Asset | Answer |
|---|---|---|---|
| `research-cnn-v1` | 纯 CNN | `research-cnn-v1.ncnn.*` | image-only signed-gain CNN |
| `research-exif-v1` | EXIF 参数辅助预测 | `research-exif-v1.ncnn.*` + `research_exif_level_data.inc` | a spatial network plus an EXIF level estimator |

Without decoded capture parameters, the panel selects CNN and hides model
selection. When capture parameters are present, both choices are shown.
The selector and strength controls share one section so a hidden selector
leaves no empty padded section. Incomplete capture parameters still use the
runtime fallback described below.

`HyperDR model-list --json` reports the table, and the panel reads it once per
executable version instead of carrying its own copy. Each model also has a
`*.manifest.json` recording its research run, fold and seed, checkpoint and
export hashes, and the conventions it was built with.

### The capture-assisted model

Model 2 predicts the *shape* of the gain and takes its overall level from six
ordinary capture settings:

| order | field | Exif tag | model input |
|---|---|---|---|
| 0 | ISO | 34855 | `log2(max(iso, 1))` |
| 1 | exposure time | 33434 | `log2(max(seconds, 1e-6))` |
| 2 | f-number | 33437 | as recorded |
| 3 | exposure compensation | 37380 (`0x9204`) | signed EV, not logged |
| 4 | focal length | 37386 | millimetres |
| 5 | 35 mm-equivalent focal length | 41989 | millimetres |

`gain = (net(image) − mean(net(image))) + estimator(capture)`. The estimator is
a fitted `SimpleImputer(median) + HistGradientBoostingRegressor` whose arrays are
compiled in as static tables; no Python, scikit-learn or second inference runtime
is involved at run time.

The capture is complete only when all six fields are present, finite, and — for
ISO, exposure time and f-number — positive. Exposure compensation of `0 EV` is a
value: presence is carried by the tag, never inferred from truthiness. A zero in
either focal-length tag counts as absent, because Exif defines it as “unknown”.

When the capture is incomplete, model 2 answers with model 1's prediction and
says so: the packet reports `effectiveModelId: research-cnn-v1`,
`inferenceMode: pixel_only_fallback` and a `fallbackReason` naming the fields.
The shape-only network is deliberately never used on its own — its training
target had the per-image level removed, so its raw output is not a complete gain.
A damaged asset or a failed inference is an error, not a fallback.

Every supported input route reaches the model with the same capture vector. The
Exif-based decoders get it from the parsed block; RAW additionally reads the
file's own Exif prefix, because LibRaw exposes none of the exposure compensation
and no presence information at all.

### Reconstruction offsets

The research reconstruction is `max((base + 1e-5) × 2^gain − 1e-5, 0)`, so both
research models carry `base_offset = alternate_offset = 1/100000` into the
ISO 21496-1 metadata. The offsets follow the
model that actually answered, so a fallback reconstructs with model 1's
convention rather than blending two curves.

### Verifying the assets

`HyperDR_Model/scripts/verify_research_models.py` checks the four claims this
integration makes, and fails rather than widening its own tolerances:

- PyTorch and ncnn on the **same** float32 tensor, so the reported number is
  conversion error and not the decode path's (bound: 1e-3 stops);
- the compiled estimator against the fitted sklearn object, including the
  presence rules (bound: 1e-5 stops);
- the fallback producing model 1's grid exactly, with the research offsets;
- every manifest hash.

`HyperDR_Model/scripts/make_capture_fixtures.py` derives the three acceptance
files from one photograph — a complete capture, a capture whose exposure
compensation is 0 EV, and one with no Exif at all. The measured result is
recorded in the dated [acceptance record](archive/research-model-acceptance.md)
and its [follow-up review](archive/research-model-review.md).

## Runtime behavior

`HyperDR convert ... --ai-model <id>` and `preview-frame` use the same
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

`HyperDR model-gain ... --ai-model <id>` is a diagnostic/panel probe. It
writes one binary `HYPGAIN1` packet to stdout containing JSON geometry and
identity followed by the unfiltered stride-16 float32 signed-log2 ncnn
prediction. The identity members name the model that was asked for, the one that
answered, its version, its inference mode and — when they differ — why. It does not
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
