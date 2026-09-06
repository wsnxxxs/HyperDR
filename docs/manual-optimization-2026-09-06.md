# Manual rendering optimization — 2026-09-06

Manual SDR conversion now keeps one base through zero and nonzero HDR strength.
Explicit exposure and ISO reach the SDR renderer. The panel pins photographic
style (`pop`) to zero and labels broad-highlight participation as a weight.
RAW gain is reduced from per-pixel requests, and local attenuation is no longer
cancelled by peak normalization. Requested range remains an upper budget;
encoded gain and measured rendered peak can be lower.

Performance changes reuse bilinear coordinates, gain-channel metadata and local
work buffers, combine SDR guide/gain sampling, and replace decoded-grid sorting
with an exact 256-code histogram. Single-channel reconstruction computes one
multiplier for all three RGB channels.

## Measurement

Local MSVC 19.44 Release/core build, synthetic horizontal ramp and small bright
patch, aspect ratio 3:2. Fixed exposure, 2.5-stop range, strength 0.4, `pop=0`,
broad-highlight weight 1. Each case has one warm-up and five measured renders;
the table reports median milliseconds. The baseline uses native libraries saved
from the working tree before this task. Input generation, decoding, encoding,
process startup and browser presentation are excluded. Output appearance
deliberately changes, so these timings are not a byte-identical optimization
comparison or a promise of end-to-end application latency.

| Width / input | Render before | Render after | Reconstruct before | Reconstruct after |
| --- | ---: | ---: | ---: | ---: |
| 1024 / scene referred | 48.97 | 39.60 | 7.77 | 3.52 |
| 1024 / SDR | 43.98 | 40.14 | 6.83 | 3.36 |
| 3072 / scene referred | 269.42 | 183.20 | 65.84 | 27.62 |
| 3072 / SDR | 239.60 | 228.34 | 57.00 | 25.38 |

At 3072 pixels, combined render/reconstruction time falls by about 37% for the
scene-referred fixture and 14% for SDR. The reusable local diagnostic and raw
measurements are in the ignored `build-core/manual-profile/` directory.

## Validation

- 30 core CTest checks and three native schema/curve integration checks passed.
- 165 panel Python checks passed; one existing check was skipped. Frontend
  syntax, behavior, role wiring and translation checks passed.
- The codec-enabled Release executable exported and self-verified generated
  gradient/colour input as Adaptive HEIC, Ultra HDR JPEG, PQ HEIC, HLG HEIC,
  PQ AVIF and HLG AVIF.
- Native CLI previews at strength 0, 0.001, 0.4 and 1 have byte-identical SDR
  planes. Their maximum HDR channels are 1.0000, 1.0014, 1.7389 and 3.9872.
- Regressions cover small highlights whose cell means are below the knee,
  retained local attenuation, explicit SDR exposure and ISO, RAW base stability,
  histogram/reference-sort agreement and cached/reference-sampler agreement.

## Follow-up: analysis reuse and environment resolution

RAW preview and conversion requests now persist source luminance samples and
gain-cell means/peaks beside the decoded-image cache. The key includes the source
digest and decode settings/geometry, but excludes look controls. Exposure and
headroom selection still run with the current settings and capture metadata.
Analysis entries share the existing disk budget and are rebuilt when missing,
truncated or invalid. The cache is used only when a decode cache is configured.

Broad environment statistics now use a grid with a maximum edge of 768 cells.
Log luminance, its second moment and SDR guide luminance are reduced separately,
then filtered and interpolated back. The second moment retains texture/noise
variance during reduction. Per-pixel gain requests, the fine gain grid and its
edge-aware filter keep their existing resolution. Grids up to 768 cells retain
their original statistics directly.

### Follow-up measurement

The baseline below is the completed first iteration (`f5f9f35`), with the same
compiler, synthetic fixture and median-of-five method described above. No disk
analysis cache is used in this render benchmark; it isolates the coarse-grid
change and parallel local weighting. Small-image timings show a slight overhead,
and the measured 3072-pixel render improvement is modest (about 2–3%). At 6144
pixels the render stage improves by about 5% for scene-referred input and 16%
for SDR.

| Width / input | Render before (ms) | Render after (ms) |
| --- | ---: | ---: |
| 1024 / scene referred | 39.48 | 40.30 |
| 1024 / SDR | 40.49 | 41.17 |
| 3072 / scene referred | 189.16 | 185.72 |
| 3072 / SDR | 215.90 | 208.63 |
| 6144 / scene referred | 702.49 | 667.22 |
| 6144 / SDR | 905.80 | 759.93 |

Separately, a periodic RGB fixture compares recomputing RAW source analysis with
reading its warm disk cache, including allocation and validation. Measurements
exclude decode, rendering, encoding, process startup and the first cache write.
The cache hit and fresh analysis retain exactly equal samples and cell values.
Bulk stdio reads replace a measured slower MSVC file-stream read, and large cell
arrays are validated by the existing row pool.

| Width | Fresh analysis (ms) | Warm cache (ms) | Cache bytes |
| --- | ---: | ---: | ---: |
| 1024 | 3.11 | 1.63 | 2,327,936 |
| 3072 | 9.17 | 5.91 | 13,394,756 |
| 6144 | 24.23 | 20.24 | 51,136,996 |

These are local component measurements, not end-to-end speed guarantees. The
diagnostics and CSVs are in the ignored `build-core/manual-analysis-profile/`.

### Follow-up validation

- 31 core CTest checks and three native schema/curve integration checks passed;
  the final parallel cache reader also passed its focused regression test.
- Cache tests cover exact rendering after look changes, source/decode identity
  changes, shared pruning, truncated entries and a nonfinite cell value.
- A fine-grid isolated highlight survives coarse environment analysis without
  leaking into a dark field. Two scales of a broad scene differ by less than
  0.01 stops on average at the sampled locations.
- Native CLI comparisons on three workspace photographs (maximum edges 960 to
  1280) retain byte-identical base and HDR planes.
- A 1600-pixel RAW-derived SDR base and its deliberately enlarged 3072-pixel
  version exercise the coarse path. Both retain byte-identical SDR planes.
  HDR mean absolute channel differences are 0.000257 and 0.0000675 relative to
  SDR white 1; 99th-percentile differences are 0.00335 and 0.00112. Their maxima
  are 0.04956 and 0.02142, so this is not a byte-identical HDR optimization.
- Comparing 800-pixel previews with downsampled full-size renders, mean HDR
  differences change from 0.016825 to 0.016801 for the 1600-pixel source and
  from 0.008804 to 0.008793 for the enlarged fixture. Existing scale differences
  remain; the coarse grid does not materially increase them in these examples.
- The SDR-display comparison was visually inspected, including an amplified
  difference view. Available material contains no original camera RAW for
  end-to-end RAW decode acceptance, and an HDR display was not used. The enlarged
  fixture checks scale behaviour, not additional real photographic detail.
- The updated codec-enabled Release executable exports and self-verifies all
  six formats listed above. Photo metrics, preview packets and the comparison
  image are in the ignored `build-release/manual-analysis-qa/` directory.

## Final pass: fine filtering, encoding and preview delivery

The remaining implementation work identified in this pass is complete:

- Fine-grid box means use separable, double-precision sliding sums. Vertical
  windows process adjacent columns together, avoiding the summed-area table's
  full-height strided scan. Scratch-buffer size and edge cropping are unchanged.
- Gamma selection reuses normalized samples/weights and the exact 256 possible
  decoded values for each candidate. Candidate choices, stratified sampling,
  quantization and error weighting are unchanged; no approximate power function
  or interpolated lookup is introduced.
- Decoded float caches use the same bulk stdio reader as RAW analysis caches.
  Native preview packets reserve both planes together and validate/copy rows in
  parallel, keeping the existing float32 wire format.
- Preview cache identity includes the converter path, modification time and
  size. A converter rebuild refreshes the next requested frame. Returning to a
  cached slider value cancels an obsolete in-flight render before returning it.

### Final-pass measurement

The baseline is the previous completed iteration (`45fa2ca`), including the
working tree's existing colour-gamut changes in both builds. The local component
benchmark uses the same ramp/specular fixture, one warm-up and five trials as
above. Timings are medians in milliseconds; process startup and I/O are excluded.

| Width / input | Render before | Render after |
| --- | ---: | ---: |
| 1024 / scene referred | 39.69 | 29.33 |
| 1024 / SDR | 40.12 | 32.40 |
| 3072 / scene referred | 180.25 | 159.11 |
| 3072 / SDR | 218.40 | 207.88 |
| 6144 / scene referred | 624.22 | 583.98 |
| 6144 / SDR | 729.45 | 695.35 |

A separate six-call box-filter benchmark at radius 8 falls from 16.50 to 5.63 ms
on a 1536×1024 grid and from 53.46 to 27.64 ms on a 3072×2048 grid. On a small
512×341 grid the measured 2.78 versus 2.89 ms is a slight overhead; the benefit
is in larger grids. Render timings include other work and vary with scheduling,
so component speedups should not be added together.

The following **whole CLI preview** measurement includes process startup, a warm
decoded-cache read, rendering, HDR reconstruction, packet packing and output
file writing. It excludes HTTP transfer, Python packet reads and browser/GPU
presentation. It uses the same deliberately enlarged sunset photograph as the
scale diagnostic, fixed 2-stop budget, strength 0.4, participation 0.35, and
five exposure-bias changes from 0.45 to 0.65 EV after a warm-up. Both versions
reuse the same decoded source cache; no rendered-frame cache is used.

| Preview maximum edge | Before (ms) | After (ms) | Reduction |
| --- | ---: | ---: | ---: |
| 1024 | 162.74 | 118.82 | 27% |
| 3072 | 757.45 | 454.04 | 40% |

The final SDR and HDR float planes are byte-identical between these versions at
both resolutions. These remain local sample measurements, not guarantees for
other hardware or uncached camera decoding. Scripts/CSVs are in the ignored
`build-core/manual-final-profile/`; CLI timings are in
`build-release/manual-final-qa/preview-timing.json`.

### Final-pass validation and acceptance status

- All 31 core CTest checks and three native schema/curve checks pass.
- All 167 panel Python checks pass; one existing check is skipped.
- Direct local-sum comparisons cover cropped filter windows, negative values,
  clamping, radius zero, windows larger than the image and column-tile boundaries.
  The existing large-grid precision, guided-filter and render regressions pass.
- The gamma search agrees with direct power evaluation. Cache round trips retain
  decoded pixels and capture/decode metadata, and malformed cache entries remain
  misses. Preview regressions cover converter replacement and cancellation when
  returning to a cached state.
- All seven source/resolution pairs in the photographic comparison have
  byte-identical SDR and HDR float planes relative to the previous iteration.
  The earlier 800-pixel/full-size differences are also unchanged. The comparison
  image was visually inspected; packets and metrics are under the ignored
  `build-release/manual-final-photo-qa/` directory.
- The updated Release executable exports and self-verifies Adaptive HEIC,
  Ultra HDR JPEG, PQ HEIC, HLG HEIC, PQ AVIF and HLG AVIF.

The identified code optimizations are implemented and verified. Original-camera
RAW and HDR-display visual acceptance still require representative RAW files and
an HDR display; this environment's SDR photograph comparisons do not replace
those checks.
