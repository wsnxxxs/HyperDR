# Apple training-source gain maps and current HEIF output — 2026-09-23

Implementation follow-up: HyperDR subsequently adopted fixed HEVC Q95 gain
coding. The comparison below records the lossless output that motivated that
change; see the [compression study](gain-compression-study-2026-09-23.md) for
delivery validation.

The actual WSL photographs contradict two assumptions in the supplied review:
Apple does use grid gain maps, and its gain maps can use monochrome HEVC RExt.
The clearest remaining coding difference is HyperDR's lossless auxiliary stream
with transquant bypass and Level 8.5. That is a candidate cause of compatibility
problems, not a demonstrated cause of Photos zoom failures.

## Scope and evidence

Read-only census of all **847** originals under
`/home/ryan/datasets/hyperdr-apple/originals`, cross-referenced against the
dataset's manifests and current research training code. All 847 containers
parsed successfully. There are 459 native ISO/tmap images and 388 legacy Apple
images. Older documentation describing an 811-image corpus is a historical
snapshot; it does not describe the current corpus.

The current `research-cnn-v1` manifest identifies run `baseline-f0-s908` in
the sibling `HyperDR_research` project. Its preparation report contains 418
native ISO development images. Its saved configuration assigns **273** to
training, 36 to validation, 36 to calibration, and 73 to score. Thus the whole
847-image archive is not the training partition of this checkpoint. All 273
training originals have monochrome RExt grid gain maps. The pixel spot checks
below use only five IDs from that saved training partition; no model evaluation,
retraining, partition change, or evaluation-ledger operation was performed.

The census walks item types, property associations, grid `dimg` references,
`auxC`/`auxl`, image extents, hvcC records, and every gain tile's VPS/SPS/PPS.
It removes emulation-prevention bytes before parsing NAL fields. Results and
scripts remain in the ignored local directory `output/wsl-gainmap-review/`:
`audit_containers.py`, `containers.json`, `summary.json`, `spotcheck_labels.py`,
and `label_spotchecks.json`. Photos and training data were not copied into Git.

## Container and codec comparison

| Property | Apple source photographs | Current HyperDR Adaptive output |
| --- | --- | --- |
| Gain sample format | All 847: 8-bit monochrome, `chroma_format_idc=0` | 8-bit YCbCr 4:2:0 with neutral chroma |
| Gain profile | All 847: RExt, profile 4, consistent across hvcC/VPS/SPS | Main Still Picture, profile 3 |
| Gain coding tools | All 847: PPS transquant bypass off and transform skip off; conventional lossy coding configuration | Lossless enabled; PPS bypass on |
| Gain level | All 459 native ISO images: Level 3 or 3.1; entire archive: 249 Level 3, 227 Level 3.1, 1 Level 4, 370 Level 5 | Saved lossless output: `level_idc=255`, Level 8.5 |
| Gain item type | 476 grids, 371 single `hvc1`; **all 459 native ISO images use grids** | Single item through 3072 pixels per dimension; larger ordinary maps use grids |
| Gain grid geometry | 248 grids of 12 tiles, 227 of 15, 1 of 30; native ISO coded tiles are 512×512, 640×896, 768×704, or 896×1024 | Grid tiles are 2048×2048 |
| Gain dimensions | 846/847 have half the base width and height in their `ispe` properties | Ordinary rendition-derived gain is full resolution; AI/external gain can retain a smaller supplied grid |
| Gain auxiliary type | All 847: `urn:com:apple:photo:2020:aux:hdrgainmap`, including native tmap files | `urn:iso:std:iso:ts:21496:-1` |
| Auxiliary relationship | All 847: gain `auxl` points to the primary base grid | Gain `auxl` points to the base; tmap separately references base and gain |
| Native ISO gain `nclx` | All 459: primaries/transfer/matrix `2/2/2`, full range | `2/2/1`, full range, describing YCbCr encoding |
| Primary base | All 847: 8-bit 4:2:0 Main Still Picture grids | 8-bit Main Still Picture or, after the earlier fix, 10-bit Main10 |

The dimensions above are coded `ispe` dimensions, before orientation and clean
aperture interpretation. The exception is one 4032×3024 base paired with a
2856×2142 gain map. The most common pair is 4032×3024 with 2016×1512 gain
(604 files). Apple also ships a 4032×3024 **gain** grid in this corpus, so neither
grids nor gain dimensions above HyperDR's 3072 threshold can be rejected merely
because of their presence. This does not establish support for every tile size,
codec tool combination, level, OS, or export graph.

PPS initial QP fields were also read, but they are not an encoder quality setting
or the complete per-slice/per-block QP. Original uncompressed camera gain planes
are unavailable, so this inspection cannot quantify the camera encoder's loss.
Likewise, the presence of these files in an Apple-origin corpus is not a device
display test performed during this review.

For a direct current-output control, the same parser read
`output/gain-compression-study/sdr-source/photo-3000x2000-hyperdr.heic`:
3000×2000 gain, profile 3, Level 8.5, bypass enabled, ISO auxiliary URN,
`2/2/1` full-range nclx, and an `auxl` link to its base. The gain is a single
image even though this sample's base is a grid. Thus base grids and gain grids
must not be conflated.

## What the model actually learns

The source pipeline is:

1. Decode the original HEIC auxiliary image with pillow-heif and save its
   decoded 8-bit plane as PNG. PNG preserves those decoded values; it does not
   make the original HEVC encoding lossless.
2. For native ISO images, parse each original tmap and compute signed gain in
   stops as `G = gain_min + (gain_max - gain_min) * (code / 255)^(1 / gamma)`.
   Store a float32 canonical plane and its metadata. Legacy labels use a
   separate Rec.709/headroom-derived path with lower confidence.
3. Area-resample the canonical plane into the stride-16 training target,
   usually 64×48 or 48×64 for a 1024-long-side proxy.
4. Train against signed log2 gain, then package model predictions into gain
   image codes and metadata during export.

The sibling project's `src/prepare.py` selects native ISO development images;
`src/train_experiments.py` reads `training/gain_grid_stride16_f32_v2` for its
original cache. The saved baseline configuration uses resolution 1024. The
256×192 shape in the model export manifest is a graph export example, not the
training resolution. Runtime `make_native_model_input` also defaults to a
1024-pixel long side and stride 16. The AI adapter then lifts coarse predictions
to at least the development gain-map dimensions before encoding, retaining
already finer supplied maps. For example, the subsequent CLI delivery check
exports a 1500×1000 gain map for a 3000×2000 AI result. The prediction tensor's
stride-16 dimensions are not the encoded image dimensions. The ordinary
edited-rendition path computes full-resolution gain.

For the 459 native ISO originals, all tmap records use base-color-space flag
`0x40`, base headroom 0, and base/alternate offsets of `1e-5`. Gamma ranges from
0.559082 to 2.111328. The declared minimum gain is negative in 418 files and
zero in 41; a negative metadata minimum does not imply negative actual pixels.
Research-model runtime already preserves signed gains and uses the same
`1e-5` reconstruction offsets. An ordinary export's nonnegative range and zero
offsets follow its own generated endpoints; that difference alone is not a
metadata defect.

The five spot checks were the first five IDs in the baseline's saved training
partition: `apl_01e2408059a3cf5adf92`, `apl_0206aa3ef1b2f8c1a516`,
`apl_02d9cdcdf24d45c18c00`, `apl_0406c1f59d39d51693ee`, and
`apl_0431ef219e4665c2aebc`.

For all five:

- Fresh auxiliary decoding exactly matched the cached PNG, including shape.
- Canonical float32 files passed their sidecar hash checks; decoding original
  tmap metadata again reproduced their values with maximum absolute error 0.
- `INTER_AREA` reduction reproduced the saved v2 training grids with maximum
  absolute error 0 stops.

These checks found no extraction or label-curve mismatch in the selected
samples. They do not measure model prediction accuracy across the corpus.

## Implications and next compatibility experiment

**Grid itself is not the diagnosis.** The native ISO images used to train the
current baseline all have grid gain maps. Native tile sizes are nevertheless
smaller than HyperDR's, and their gain levels are only 3/3.1. Tile geometry and
level therefore remain separate variables worth controlling if necessary.

**RExt itself is not the diagnosis either.** Apple-origin monochrome gain maps
all signal profile 4. Profile numbers alone do not describe all constraints or
decoder paths. This evidence does not establish that the former 10-bit 4:2:0
RExt base output worked on every Apple reader, nor does the earlier Main10
normalization prove that it fixed the reported zoom behavior. The encoder's
unsupported blanket comment about iOS and monochrome RExt has been corrected.

**Try full-resolution high-quality lossy gain first.** The contrast with Apple's
ordinary lossy configuration strengthens the hypothesis from the
[compression study](gain-compression-study-2026-09-23.md). That study already
measured small added brightness errors for full-resolution Q95 while removing
bypass and Level 8.5. It did not prove an iPhone fix or a universal perceptual
threshold. Keep base, gain resolution, gain metadata and container graph fixed
for the initial lossless/Q95 comparison; compare HDR and detail at normal size
and above 100% zoom on the affected Apple device.

**Treat the auxiliary identifier as a separate hypothesis.** Even native ISO
Apple files in this corpus retain the Apple auxiliary URN. HyperDR's different
URN may select a different reader path, but this census does not establish that
its URN is invalid. Do not relabel the payload as legacy Apple gain or apply a
legacy transfer curve merely to imitate the identifier. Apple's
[WWDC24 explanation](https://developer.apple.com/videos/play/wwdc2024/10177/)
describes the transition from Apple Gain Map to new Adaptive HDR mathematics,
metadata, and tmap alternates. Metadata semantics and the auxiliary identifier
must be assessed together.

The model sees decoded gain values, not HEVC headers. The training targets are
already much coarser than the original camera maps. Training-source compression
can affect the learned target values, but it cannot explain an output decoder
rejecting Level 8.5 or discovering the wrong auxiliary item. Separate display
compatibility from prediction quality. No production encoding or model defaults
were changed during this comparison.
