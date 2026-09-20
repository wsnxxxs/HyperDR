# Research model selector — acceptance record

Follow-up: the implementation was reviewed and repaired on 2026-09-14. See
[the review record](research-model-review.md) for current test results, actual
browser screenshots, UI exports, cache fixes, and the repository-history caveat.
The numbers below are the original delivery record, not the follow-up run.

Date: 2026-09-14. Application `C:\Users\Ryan\Desktop\HyperDR` at `3059f37` plus
this branch's changes; research workspace `C:\Users\Ryan\Desktop\HyperDR_research`
at `86099d9`.

Development build: `build-release/Release/HyperDR.exe`, configured with
`HYPERDR_WITH_NCNN=ON` (ncnn 20260526) against
`build-release/vcpkg_installed/x64-windows`.

## What was delivered

| id | Asset | Research run | fold / seed |
|---|---|---|---|
| `production-v3` | `production-v3.ncnn.{param,bin}` (unchanged) | — | frozen incumbent |
| `research-cnn-v1` | `research-cnn-v1.ncnn.{param,bin}` | `baseline-f0-s908` | 0 / 908 |
| `research-exif-v1` | `research-exif-v1.ncnn.{param,bin}` + compiled estimator | `shape_only-f0-s908` | 0 / 908 |

Checkpoints: `baseline-f0-s908/best.pt`
`adbed708fdbcdfb43bca74d6062b4c1f0bd5909b7fdb22fcc25e98a509e77039`,
`shape_only-f0-s908/best.pt`
`5dccbb2844ab480585b0770642fc4299ddd8bb4a11af625b84b10d4f6278df28`, both
re-verified against the plan. Each model has a `*.manifest.json` recording the
run, fold, seed, checkpoint and export hashes, architecture, input/output
contract, capture field order, fallback and reconstruction offset; every hash in
both manifests was re-computed and matched.

The incumbent's `production-v3.ncnn.bin` is byte-identical to the version
recorded in its own manifest (`35568bc4…`), so the compatibility option is the
same asset as before.

## Measured results

All numbers are from `HyperDR_Model/scripts/verify_research_models.py`
(`.workbuddy/verify/report.json`) on one Sony ARW frame.

| Claim | Method | Result | Bound |
|---|---|---|---|
| CNN conversion | PyTorch and ncnn on the **same** float32 tensor from `model-input` | max difference **3.81e-6 stops** | 1e-3 |
| Estimator is the fitted object | model 2 on a zero tensor: the grid's mean equals level after `(net − mean) + level`; individual pixels need not be constant | max difference **5.87e-8 stops** over 8 fold rows + 3 constructed captures | 1e-5 |
| Presence rules | one field absent → fallback naming it; `exposure_bias_ev = 0` → complete | both hold | — |
| Fallback | model 2 with no capture, same tensor as model 1 | grids **byte-identical** (max difference 0.0); `effectiveModelId = research-cnn-v1`, `inferenceMode = pixel_only_fallback` | exact |
| Reconstruction offset | `base_offset` / `alternate_offset` in the packet and in the encoded payload | **1e-5** for both research models, **0** for the incumbent | — |

The conversion and estimator comparisons use the same input tensor and the same
source file respectively but are reported separately, so a conversion error and a
decode-path difference cannot be confused for one another.

## End-to-end exports

One ARW frame exported four ways, identical settings
(`--encoding adaptive --gain-strength 1 --highlight-recovery blend --quality 90
--depth 8`), all `self_verified`:

| Run | report `model_id` | `inference_mode` | gain range (stops) | bytes |
|---|---|---|---|---|
| `research-exif-v1` | `research-exif-v1` | `exif_assisted` | 0.000 – 1.874 | 22 075 450 |
| `research-cnn-v1` | `research-cnn-v1` | `pixel_only` | 0.000 – 2.505 | 22 078 792 |
| `production-v3` | `production-v3` | `pixel_only` | 0.000 – 1.932 | 22 097 467 |
| manual | `none` | `none` | 0.000 – 1.495 | 22 465 533 |

Four distinct outputs with four distinct gain ranges: the selector reaches four
different implementations rather than one model under three names.

## Capture-presence evidence

`.workbuddy/verify/fixtures/`, all three derived from one real frame by
`make_capture_fixtures.py`, which fails if they do not behave as intended:

| file | what it is | model 2 answered with |
|---|---|---|
| `full-exif.jpg` | the frame with the Exif HyperDR itself writes — all six tags | `exif_assisted` |
| `zero-bias.jpg` | the same, with `ExposureBiasValue` rewritten to `0 EV` | `exif_assisted` |
| `no-exif.jpg` | the same frame with no Exif block | `pixel_only_fallback`, reason `missing_capture_fields:iso:exposure_seconds:f_number:exposure_bias_ev:focal_length_mm:focal_length_35mm` |

`zero-bias.jpg` is the case that matters: a truthiness test on the exposure
compensation would report it as a missing tag. It does not.

## Compatibility

| Request | Result |
|---|---|
| `model-list --json` | three models, `defaultModelId: production-v3`, `research-exif-v1` reported with `requiresExif: true` and `fallbackModelId: research-cnn-v1` |
| `--ai-model` with no value | the incumbent |
| `--ai-model embedded` | the incumbent |
| `--ai-model research-cnn-v2` | `unknown AI model id 'research-cnn-v2'; known ids are …`, exit 2, no file opened |
| no `--ai-model` | manual path, `model_id: none` |
| `HYPERDR_MODEL_ENABLED=0` | unchanged: AI refused with the policy reason |

## Test suites

- C++ (`build-core`, five binaries): `exif_test`, `iso_gain_map_test`,
  `native_model_test`, `cli_test`, `report_test` — all pass. New cases cover the
  capture-presence rules and the SRATIONAL round trip, the base-offset payload
  round trip, the closed model table, identity and offsets following the
  effective model, the estimator against recorded scikit-learn values, the
  `--ai-model` sentinel and unknown-id rejection, and the model-list table.
- Python: `177 passed, 1 failed`. The failure is
  `test_session.py::test_result_cannot_escape_the_session`, which also fails on
  an untouched checkout: it depends on symlink semantics, and neither
  `session.py` nor its test is modified by this work.
- Front-end (`tests/js`): all eight runners pass, including a new
  `model_ids_test.mjs` for the compatibility rule.

## Known limits

- **Interface verification is now complete for the development panel.** The
  follow-up review used the in-app Browser to exercise both models, fallback,
  restoration and actual exports; screenshots are linked in the review record.
  This does not claim a rebuilt or installed Tauri desktop package was tested.
- **The reference tooling ran outside the research environment.** `wsl.exe` is
  blocked by this machine's security policy, so the reference runner and the
  asset export ran on Windows against a purpose-built virtual environment
  (torch 2.9.1+cpu, scikit-learn 1.8.0, onnx 1.22.0, pnnx 20260526). The research
  environment used torch 2.11/CUDA; the checkpoints load strictly and the
  comparison is against the same checkpoint, so the conversion is verified, but
  the training settings were not reproduced on the training hardware.
- **scikit-learn 1.8.0 was pinned deliberately.** The saved estimator was
  pickled by that version; loading it under 1.9.1 fails, which is how the
  version was identified. Installing it is what makes the replay exact rather
  than approximate.
- **Fold 0 / seed 908 only.** Both research assets are one fold's deployment
  weights. Neither is presented as a five-fold or all-seed average.
- **RAW coverage is a smoke test.** Sony ARW is exercised; no paired RAW
  reference exists, so no accuracy claim is made for RAW beyond the code path
  working and the capture vector arriving.
- **Photos used for the checks are new captures**, not members of the fold's
  score split. They demonstrate that the feature is wired to the right assets;
  they say nothing about reference-error improvement.
- The `research-*` builds need `HyperDR_Model/models/research-*.{ncnn,manifest}`.
  A build without them fails at configure time rather than offering an option
  that cannot run.

## One-minute demonstration

1. Start the panel (`python apps/panel/hyperdr_gui.py`), open the printed URL.
2. Import `.workbuddy/verify/fixtures/full-exif.jpg`.
3. Confirm manual mode hides the model dropdown. Press **AI 优化**; after
   inference, the model selector appears inside the AI settings, together with
   the version and actual-model status. A fresh install defaults to
   **模型 2 · 拍摄参数辅助增益预测**; an existing choice is remembered.
4. Select **模型 1 · 纯图像 CNN** within AI settings. The status line reads
   `已使用模型 1 · 纯图像 CNN`.
5. Switch to **模型 2 · 拍摄参数辅助增益预测**. The old frame is discarded and
   recomputed; the status line and the toast confirm model 2, and the overall
   brightness of the spatial gain changes.
6. Import `.workbuddy/verify/fixtures/no-exif.jpg`, keep model 2 selected, and
   press **AI 优化**. The selection stays on model 2 while the status line reads
   `拍摄参数不完整（感光度、曝光时间、光圈、曝光补偿、焦距、等效焦距），已使用模型 1 · 纯图像 CNN`.
7. Export with the same format for the two runs and compare the two files.

Reproduce the numeric record:

```bash
python HyperDR_Model/scripts/verify_research_models.py \
  --source <a photograph> --research-root <research workspace> \
  --report .workbuddy/verify/report.json

python HyperDR_Model/scripts/make_capture_fixtures.py \
  --exe build-release/Release/HyperDR.exe \
  --source <a photograph> --output-dir .workbuddy/verify/fixtures
```
