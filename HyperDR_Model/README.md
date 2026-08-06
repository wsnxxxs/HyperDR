# HyperDR-ML

Training workspace for predicting Apple-style perceptual HDR gain maps from SDR
photographs. The ML project owns extraction, target construction, training,
evaluation, and inference; the separate HyperDR project owns final encoding.

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

`headroom == 1` is a valid all-zero absolute target but is explicitly marked
ineligible for `per_image` normalization. The dataset loader also rejects
non-positive or non-finite per-image scales and all non-finite tensors.

`fixed_3stops` intentionally clips log2 gain above 3 stops. Every training run
writes `target-audit.json` with the affected sample and pixel fractions; this
makes the clipping policy visible instead of silently changing labels.

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

Important behavior:

- `xmp` uses explicit XMP headroom labels; `all` also includes reverse-engineered
  legacy MakerNote estimates.
- Reconstruction, gradient, and global-mean terms are computed per image and
  then averaged. Epoch metrics use the same image-weighted aggregation.
- In `fixed_3stops`, the reported highlight metric is
  `absolute_highlight_mae_stops`. In `per_image`, it is
  `relative_high_gain_mae`; their meanings are not mixed.
- The final sigmoid bias is initialized from the masked training-target mean.
- Checkpoints contain model, optimizer, scheduler, epoch, best metrics, Python,
  NumPy, PyTorch, CUDA, and DataLoader-generator RNG states.
- `learning_rate` is the rate used for the recorded epoch;
  `next_learning_rate` is the post-scheduler rate.
- CUDA peak memory is reset at the start of every epoch.

Resume an interrupted run with the original training arguments:

```bash
PYTHONPATH=. .venv/bin/python train.py \
  ...same arguments... \
  --resume ~/runs/hyperdr/xmp-fixed3-baseline/last.pt
```

The loader currently applies only paired horizontal flips. Photometric or
exposure augmentation is deliberately absent because changing SDR exposure
requires an explicit, label-consistent gain transformation. Overfitting should
be assessed with multiple seeds and validation curves rather than adding an
unjustified exposure transform.

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

## Evaluation and inference

```bash
PYTHONPATH=. .venv/bin/python evaluate_absolute.py \
  --checkpoint <best.pt> \
  --split test \
  --output <test-report.json>

PYTHONPATH=. .venv/bin/python infer_gain.py \
  --input <sdr.jpg> \
  --checkpoint <best.pt> \
  --gain-output <grid.f32> \
  --report <grid.json> \
  --dataset-root ~/datasets/hyperdr-apple \
  --device auto
```

Evaluation streams error sums and pixel counts, so batches with different
padding shapes are never concatenated. Evaluation and inference use CUDA when
available and otherwise support CPU.

The v2 gain interchange remains compatible with HyperDR's raw `.f32` consumer,
but it is a required file pair:

- `.f32`: contiguous HW little-endian float32, signed canonical log2 gain;
- JSON report: width, height, byte length, endianness, scale, contract ID,
  SHA-256 and exact ISO rational metadata.

The old v1 normalized `[0,1] + max_stops` sidecar is accepted only with an
explicit `--allow-legacy-label-schema` / `--allow-legacy-external-gain` gate.

The writer verifies the byte length after writing. Any reader must supply both
width and height and reject a file whose length is not `width * height * 4`.

## Tests

```bash
PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -p 'test_*.py' -v
PYTHONPATH=. .venv/bin/python tests/smoke.py
```

The unit suite covers 690/696/683 boundaries, mixed landscape/portrait
collation, direct unaligned model input, degenerate and non-finite targets,
per-image loss aggregation, GroupNorm channel divisibility, controlled
architecture parameter counts, and raw gain-grid validation.
