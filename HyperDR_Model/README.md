# HyperDR-ML

Training workspace for predicting Apple-style perceptual HDR gain maps from SDR
photographs. HyperDR already derives a gain map from image content; this project
learns to predict Apple-style gain maps from a corpus of Apple-rendered SDR
photographs. The ML project owns extraction, target construction, training,
evaluation, and offline export; HyperDR embeds the fixed ncnn model and owns
native inference, filtering, rendering, and final encoding.

## Setup

Validated on Ubuntu WSL2, Python 3.12, and an NVIDIA RTX 5070 Ti with
PyTorch 2.11.0+cu128.

```bash
conda create -y -p .venv python=3.12 pip
.venv/bin/pip install \
  --index-url https://download.pytorch.org/whl/cu128 \
  torch==2.11.0
.venv/bin/pip install -r requirements.txt
```

The local dataset defaults to `~/datasets/hyperdr-apple`. It is not
distributed or committed.

When this directory is refreshed from a sibling `HyperDR_Model` checkout, run
`sync_from_source.ps1`. It copies only source and contract files; datasets,
checkpoints, reports, caches, and virtual environments remain local.

## Dataset contract

Extraction, cache construction, and inference all use
`hyperdr_ml.geometry.aligned_long_side_size`. Both proxy axes are ceil-aligned
to 16, and every cached target must satisfy:

```text
target.shape == (1, proxy_height / 16, proxy_width / 16)
```

Rebuild and validate in this order:

```bash
PYTHONPATH=. .venv/bin/python scripts/extract_apple_dataset.py \
  --root ~/datasets/hyperdr-apple --long-side 1024
PYTHONPATH=. .venv/bin/python scripts/enrich_apple_metadata.py
PYTHONPATH=. .venv/bin/python scripts/build_splits.py \
  --root ~/datasets/hyperdr-apple
PYTHONPATH=. .venv/bin/python scripts/generate_canonical_gain.py
PYTHONPATH=. .venv/bin/python scripts/build_training_cache.py \
  --root ~/datasets/hyperdr-apple --long-side 1024
PYTHONPATH=. .venv/bin/python scripts/validate_dataset.py
PYTHONPATH=. .venv/bin/python scripts/audit_targets.py \
  --output ~/datasets/hyperdr-apple/reports/target-audit.json
```

Phase A labels are built separately so the frozen v1 artifacts remain
reproducible:

```bash
PYTHONPATH=. .venv/bin/python scripts/build_phase_a_labels.py \
  --root ~/datasets/hyperdr-apple --require-counts
PYTHONPATH=. .venv/bin/python scripts/phase_a_verdict.py \
  --root ~/datasets/hyperdr-apple --hyperdr-exe /path/to/HyperDR
```

The Phase A contract is `hyperdr.apple-gain-label/v2`: signed little-endian
float32 `log2(linear gain)` plus exact ISO metadata in the required JSON
sidecar. The corpus lock is `reports/phase-a-corpus-lock.json`; it records the
423 native ISO `tmap` and 388 legacy Apple samples. The old normalized/f16
labels are not silently mixed into v2 training or inference.

`headroom == 1` is a valid all-zero absolute target but is marked ineligible
for `per_image` normalization. The dataset loader also rejects
non-positive or non-finite per-image scales and all non-finite tensors.

`fixed_3stops` clips log2 gain above 3 stops by design. Every training run
writes `target-audit.json` with the affected sample and pixel fractions, so the
clipping policy stays visible instead of changing labels silently.

`build_training_cache.py` prebuilds
`assets/display-p3.icc` inside the dataset. Inference loads this fixed resource
and does not scan the manifest or proxy images for an ICC profile.

## Frozen split workflow

The current train/validation/test assignment is an immutable comparison
baseline. Initialize the lock exactly once from a reviewed existing split:

```bash
PYTHONPATH=. .venv/bin/python scripts/build_splits.py \
  --root ~/datasets/hyperdr-apple \
  --freeze-current
```

The command creates `splits/frozen-v1.json` and does not rewrite the existing
split or group files. Future normal runs preserve every frozen sample:

- a wholly new capture group goes to train;
- a new sample connected to a frozen group inherits that group's split;
- a new connection that bridges frozen splits fails before writing;
- a missing frozen sample fails before writing.

Preview a future update without changing files:

```bash
PYTHONPATH=. .venv/bin/python scripts/build_splits.py \
  --root ~/datasets/hyperdr-apple \
  --dry-run
```

Generate the reproducible read-only data-quality report with:

```bash
PYTHONPATH=. .venv/bin/python scripts/audit_dataset.py \
  --dataset-root ~/datasets/hyperdr-apple \
  --output-json reports/data-quality-audit.json \
  --output-markdown reports/data-quality-audit.md \
  --output-sql reports/data-quality-audit.sql
```

The audit reads manifests, grouping metadata, split assignments, asset
inventories, and cached gain grids. It does not move, delete, or rewrite
original photographs or training caches. The optional SQL file is a
self-contained SQLite reproduction of the bounded rows exposed in the
read-only report; it contains no raw photos or private capture timestamps.

## Training

Reproduce the production-v3 numerical recipe (this creates a new run; it does
not overwrite or relabel the frozen checkpoint):

```bash
PYTHONPATH=. .venv/bin/python train.py \
  --dataset-root ~/datasets/hyperdr-apple \
  --output-dir ~/runs/hyperdr/direct-production-v3-reproduction \
  --model-id hyperdr.direct-fixed-incumbent/v3-production \
  --label-subset iso_native --target-mode signed_stops --model direct \
  --architecture baseline --production-selection-fold 4 \
  --lambda-gradient 0.2 \
  --lambda-global-mean 0.1 --epochs 80 --batch-size 8 \
  --learning-rate 0.0003 --weight-decay 0.0001 \
  --base-channels 24 --seed 20260730
```

This matches the embedded config of `production-v3.pt`. The historical source
is upstream commit `46a4ce098304e3b79608bdaf54b7fe0be999ddb1` plus
`checkpoints/production-v3-training.patch`.

```bash
PYTHONPATH=. .venv/bin/python train.py \
  --dataset-root ~/datasets/hyperdr-apple \
  --output-dir ~/runs/hyperdr/xmp-fixed3-baseline \
  --label-subset xmp \
  --target-mode fixed_3stops \
  --architecture baseline \
  --highlight-weight 6 \
  --epochs 80 \
  --batch-size 8
```

Some behaviors worth knowing:

- `xmp` uses the explicit XMP headroom labels; `all` also includes the
  reverse-engineered legacy MakerNote estimates.
- Loss terms (reconstruction, gradient, global mean) are computed per image and
  then averaged; epoch metrics use the same image-weighted aggregation.
- The reported highlight metric follows the target mode:
  `absolute_highlight_mae_stops` for `fixed_3stops`,
  `relative_high_gain_mae` for `per_image`. The two are never mixed.
- The final sigmoid bias starts from the masked training-target mean.
- Checkpoints save the full run state — model, optimizer, scheduler, epoch,
  best metrics, and the Python, NumPy, PyTorch, CUDA, and DataLoader-generator
  RNG states — so a resumed run continues where it stopped.
- `learning_rate` records the rate for that epoch; `next_learning_rate` is the
  post-scheduler rate.
- CUDA peak memory is reset at the start of every epoch.

Resume an interrupted run with the original training arguments:

```bash
PYTHONPATH=. .venv/bin/python train.py \
  ...same arguments... \
  --resume ~/runs/hyperdr/xmp-fixed3-baseline/last.pt
```

The loader currently applies only paired horizontal flips. Photometric or
exposure augmentation is absent on purpose: changing SDR exposure would need a
matching, label-consistent gain transformation, and none is implemented. Assess
overfitting with multiple seeds and validation curves instead of adding an
exposure transform the labels cannot back up.

Architectures `baseline`, `global_conditioning`, and `dilation_pyramid` have
controlled parameter counts and can be compared on validation with:

```bash
PYTHONPATH=. .venv/bin/python scripts/summarize_validation_runs.py \
  <run-dir>... --output <summary.json>
PYTHONPATH=. .venv/bin/python scripts/diagnose_receptive_field.py \
  --checkpoint <best.pt> --split validation --output <diagnostics.json>
```

The diagnostic refuses to inspect test unless `--allow-test` is explicit.
Architecture and seed selection should use validation only; evaluate test once
after selection.

The code-level incumbent is `DirectGainMapNet` (`GainMapNet` remains a
checkpoint-compatible alias). Direct v3 freezes `baseline`, 24 base channels,
and 80 epochs; its development OOF canonical-G MAE is 0.2371 stops. See
`reports/direct-incumbent-v3.json`. That number summarizes the complete
4-fold x 3-seed OOF matrix and must not be attached to the bundled legacy
`checkpoints/best.pt`. The deployable `checkpoints/production-v3.pt` uses the
first preregistered seed, fits folds 0-3, and selects epoch 4 on fold 4 at
0.23068 capture-group-weighted MAE. That selection-fold value is not a fresh
blind-test estimate; full release provenance is in
`checkpoints/production-v3.json`.

The `reports/` directory contains generated local evaluation results and is
ignored by Git; preserve any result needed for comparison or regenerate it from
the recorded run inputs.

## Evaluation and inference

```bash
PYTHONPATH=. .venv/bin/python evaluate_absolute.py \
  --checkpoint checkpoints/production-v3.pt \
  --split selection \
  --output <test-report.json>

PYTHONPATH=. .venv/bin/python infer_gain.py \
  --input <linear-p3.f32> \
  --input-report <model-input.json> \
  --checkpoint checkpoints/production-v3.pt \
  --gain-output <grid.f32> \
  --report <grid.json> \
  --dataset-root ~/datasets/hyperdr-apple \
  --device auto
```

The research inference command above remains useful for evaluating checkpoints
and sidecar compatibility; it is not used by the packaged panel. Production
deployment exports inference-only ONNX with `export_onnx.py`, converts the
five-plane ONNX view with `scripts/convert_ncnn.py`, and embeds the resulting
ncnn param/bin in `HyperDR.exe`.

Evaluation streams error sums and pixel counts, so batches with different
padding shapes are never concatenated. Evaluation and inference use CUDA when
available and otherwise support CPU.

`production-v3.pt` selected epoch 4 on fold 4, so `--split selection` is the
honest reproducible evaluation entry. It is not a blind test. Frozen `test`
remains one-shot and requires the evaluator's explicit protocol/ledger flags.

### Deployment-matched v4 preflight

Build a separate cache through the exact HyperDR `model-input` implementation:

```bash
PYTHONPATH=. .venv/bin/python scripts/build_deployment_cache.py \
  --dataset-root ~/datasets/hyperdr-apple \
  --hyperdr-exe /mnt/c/path/to/HyperDR.exe \
  --source-dir ~/datasets/hyperdr-apple/originals \
  --fallback-sdr-dir ~/datasets/hyperdr-apple/extracted/sdr_1024 \
  --label-subset iso_native --split development --resume \
  --output-dir ~/datasets/hyperdr-apple/training/deployment_linear_p3_f32_dev_v1 \
  --target-output-dir ~/datasets/hyperdr-apple/training/deployment_gain_grid_stride16_f32_dev_v1

PYTHONPATH=. .venv/bin/python evaluate_absolute.py \
  --checkpoint checkpoints/production-v3.pt --split selection \
  --input-cache-dir ~/datasets/hyperdr-apple/training/deployment_linear_p3_f32_dev_v1 \
  --target-cache-dir ~/datasets/hyperdr-apple/training/deployment_gain_grid_stride16_f32_dev_v1 \
  --output reports/production-v3-deployment-input-selection.json
```

Start v4 from only the v3 model weights (optimizer, scheduler, epoch and run
configuration are deliberately fresh):

```bash
PYTHONPATH=. .venv/bin/python train.py \
  --dataset-root ~/datasets/hyperdr-apple \
  --input-cache-dir ~/datasets/hyperdr-apple/training/deployment_linear_p3_f32_dev_v1 \
  --target-cache-dir ~/datasets/hyperdr-apple/training/deployment_gain_grid_stride16_f32_dev_v1 \
  --output-dir ~/runs/hyperdr/direct-production-v4-deployment-matched-r1 \
  --model-id hyperdr.direct-deployment-matched/v4 \
  --initialize-from-checkpoint checkpoints/production-v3.pt \
  --label-subset iso_native --target-mode signed_stops --model direct \
  --production-selection-fold 4 --epochs 80 --batch-size 8 \
  --learning-rate 0.0003 --weight-decay 0.0001 --base-channels 24 \
  --lambda-gradient 0.2 --lambda-global-mean 0.1 --batch-by-shape
```

Candidate selection is auditable and blocks release on failure. The checked-in
v4 plan records the v3 baseline values used by these gates:

```bash
PYTHONPATH=. .venv/bin/python evaluate_absolute.py \
  --checkpoint ~/runs/hyperdr/direct-production-v4-deployment-matched-r1/best.pt \
  --split selection \
  --input-cache-dir ~/datasets/hyperdr-apple/training/deployment_linear_p3_f32_dev_v1 \
  --target-cache-dir ~/datasets/hyperdr-apple/training/deployment_gain_grid_stride16_f32_dev_v1 \
  --baseline-report reports/production-v3-deployment-input-selection.json \
  --max-capture-group-mae 0.23068 \
  --max-highlight-mae 0.26979890079237523 \
  --require-contrast-span-improvement 0.1 \
  --output reports/production-v4-deployment-input-selection.json
```

The input and target cache arguments are an inseparable pair in both training
and evaluation; using only one is rejected. The v4 recipe and completed
candidate decision are in `checkpoints/production-v4-training.json`. The r1
candidate failed the capture-group gate, so it remains an experiment and no
`production-v4.pt` or release manifest is created.

The native runtime receives the existing linear Display-P3 photographic SDR
base in memory, creates RGB/log-luminance/clipping features, and emits one
signed-log2 sample per stride-16 cell. It performs no ICC, sRGB, JPEG, or file
sidecar round trip.

The v2 file interchange remains available to offline research tools and generic
external integrations as a required pair:

- `.f32`: contiguous HW little-endian float32, signed canonical log2 gain;
- JSON report: width, height, byte length, endianness, scale, contract ID,
  SHA-256 and exact ISO rational metadata.

The old v1 normalized `[0,1] + max_stops` sidecar is only accepted through the
`--allow-legacy-label-schema` / `--allow-legacy-external-gain` gate.

The writer verifies the byte length after writing. Any reader must supply both
width and height and reject a file whose length is not `width * height * 4`.

## Focused validation

```bash
PYTHONPATH=. .venv/bin/python -m compileall -q hyperdr_ml scripts *.py
PYTHONPATH=. .venv/bin/python scripts/validate_dataset.py --help
PYTHONPATH=. .venv/bin/python infer_gain.py --help
```

There is no separate model test suite in this runtime copy. During an iteration,
run the dataset audit, training, evaluation, or inference command that owns the
behaviour being changed. The panel's model orchestration contract is covered by
the repository's focused Python checks under `tests/python/`.
