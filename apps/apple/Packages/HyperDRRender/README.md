# HyperDRRender

Shared macOS 26 / iOS 26 GPU processing, without AppKit, UIKit, C ABI or C++ interop.
HyperDRRecipe owns parameter declarations. Render currently exposes temporary typed values
in `RenderAdjustments` / `RAWAdjustments`, with the design's parameter IDs; Recipe integration
can map to these without changing the shaders.

```swift
let renderer = try RenderEngine()
let source = try await renderer.load(url) // caller holds the security scope
var edit = RenderAdjustments()
edit.tone.exposure = 0.25
// RAW can also select .capturedExpand; SDR defaults to expansion.
let preview = try await renderer.render(source, adjustments: edit,
    size: PixelSize(width: 2560, height: 1707))
try await renderer.renderStripes(source, adjustments: edit, rows: 256) { stripe in
    // Consume textures or RenderEngine.readPixels(stripe), then release them.
}
```

`RenderEngine` is an actor. Cancellation is checked around decode, GPU submission and stripes.
System decode and submitted GPU work finish before cancellation is reported; cancelled results
are discarded. Textures exposed to clients are read-only. All public textures/readbacks use
top-down rows; `RenderSource`'s CIImages retain Core Image's bottom-left coordinates.

## Sources and output pairs

ImageIO opens JPEG/PNG/TIFF/HEIC/AVIF and classifies SDR / PQ or HLG HDR / dual. Original
ISO/Apple auxiliary bytes, normalized encoded texture (one or three channels), metadata,
gamma/min/max, offsets, headrooms and gain-working gamut remain on the source. System HDR
reconstruction handles legacy Apple data without a luminance-ratio approximation.

RAW uses G2: boost 1, file boostShadow/baseline, exposure 0, LTM 0, EDR 1, contrast 0,
as-shot temperature/tint, and selectable lens correction. **Apple's original detail, sharpness
and noise-reduction defaults are retained**. This intentionally replaces P7-0's neutral-detail
measurement baseline. `SourceOptions.raw` supplies optional temperature/tint/NR/sharpness;
nil means Apple's/file defaults. `rawSettings` records actual values and supported controls.
Changing these options invalidates the development cache. Full-quality development is used;
no draft-preview policy is introduced by this package.

Processing is RGBA32Float extended-linear Display P3, SDR white 1. Generated pairs have
RGBA32Float SDR base and R32Float log2 gain, zero offsets: `HDR = base * exp2(gain)`.
Source decomposition is unlimited max-channel division; downstream HDR range applies a soft
shoulder, so changing range/strength never changes which SDR base was selected.

Dual sources have three paths:

* Default whole-image and HDR parameters reuse the author's original base and encoded gain
  unchanged (`authored`). Full-size renders reuse original textures, including native gain size;
  resize/stripes resample the requested grid. `PlanePixels.gainSize` may differ from base size.
* HDR-only edits retain the native author base (`editedAuthored`). ISO gains are decoded and
  transformed directly. Offsets are retained, working gamut is retained, and the output is
  three-channel float **log2 gain**, tagged `GainEncoding.isoLog2`. Reconstruct in that gamut:
  `HDR = (base + baseOffset) * exp2(gain) - alternateOffset`. Equal offsets give `g *= strength`;
  unequal offsets interpolate from the exact neutral gain, so strength zero equals the base.
  Legacy Apple edits use system HDR then exact per-channel inversion. Range uses the same
  exponential shoulder and inverse ISO formula. HDR disabled returns base plus zero gain.
* Any tone/color/active-LUT edit reconstructs linear-P3 HDR, processes it, and outputs a scalar
  zero-offset split (`resplit`). This follows the Lead's resolved H1 exception, replacing the
  design draft's older dual-base editing language. Export fallback for writers lacking RGB gain
  support belongs to P7-3.

## Processing order and formulas

The fused graph is equivalent to RAW development → non-RAW white-balance matrix → exposure →
contrast/highlights/shadows/blacks → vibrance/saturation → LUT → captured/analytic HDR →
strength/range → SDR highlight rolloff. `AdjustmentNode` exposes each of the nine point
operators separately; use these before decomposition. The fused render API handles pair
semantics and spatial analysis. Point nodes require exactly their output region; the fixed
analysis graph handles spatial neighborhoods independently of stripe boundaries.

* Exposure is linear `2^EV`; positive SDR exposure uses an exponential shoulder above Y=.48.
* Contrast maps signed control logarithmically to c=.6…1.6. Below .18 it uses AE-3's power.
  Above .18, t=(Y-.18)/.82 and `Y'=.18+.82*(t+(c-1)*t*(1-t)^2)`; black, gray and white are
  fixed, the derivative is c at gray and **1 at white**. Y≥1 is unchanged.
* SDR highlights use a smooth .4…1 mask with fixed white. HDR highlights use
  `1+(Y-1)*2^(2*amount)`, continuous and monotone above white. Shadows stop at Y=.5; black
  adjustment stops at .1 and supports lifting exact black.
* Non-RAW warmth/tint use a diagonal transform plus a neutral-axis correction, a linear matrix
  preserving P3 Y. Vibrance uses render_common_chroma's saturation weight; saturation scales
  chroma uniformly. Oklab P3 fitting uses an upper bound at least the input RGB maximum,
  retaining HDR Y instead of fitting highlights into SDR.
* `.cube` supports 1D/3D, red-fastest order, DOMAIN_MIN/MAX and INPUT_RANGE, sRGB/P3/Rec.709,
  HLG/PQ (203-nit SDR white), S-Log3/S-Gamut3.Cine for RAW. Strength mixes in linear light.
  SDR LUT changes the base with gain retained; HDR/Log LUT changes HDR before decomposition.
  Zero strength bypasses all conversions. 3D interpolation uses explicit float trilinear reads.
* Analytic expansion uses a fixed grid with longest edge 768, integrating every source pixel
  into cells once. Local log-luminance contrast identifies small speculars; coverage supplies a
  broad-region floor; local variance suppresses dark noise. Separable box statistics and a
  guided filter produce an edge-aware stop map. RAW combines captured and expansion by max.
  Auto expansion capacity is .5…3 stops from base peak. SDR/RAW auto capacity is capped at 3;
  imported HDR/dual auto retains at least original source headroom, capped at 4. The source
  floor includes original pixel peak, system content headroom and ISO headroom tags, and
  remains independent of edits. Expansion start defaults to .25, coverage .6. These choices follow the
  old engine's semantics, without requiring numeric parity.
* Range overflow uses an exponential shoulder above `1+.75*(2^range-1)`, asymptotic to capacity,
  with derivative 1 at the knee. A global overflow gate leaves valid default HDR unchanged.
  Modified-strength/expansion gating uses a conservative gain bound. The SDR LUT identity-HDR
  case gates using actual reconstructed peak, retaining gain for pairs already within range.
* SDR rolloff begins at base max-channel .7, blends toward an exponential shoulder, and adds
  `log2(oldBasePeak/newBasePeak)` to gain. This changes SDR while preserving HDR exactly within
  float tolerance. Only HDR/RAW expose rolloff; authored dual bases remain unchanged.

Two intentional math changes from older implementations: contrast fixes the white derivative;
non-P3 SDR LUT input uses constant-Y straight gamut compression to Rec.709 rather than the
old engine's Oklab input compression. LUT table/domain/transfer/linear-strength semantics remain.

## Caches, limits and P7-1b

The engine retains one opened/materialized source, optional dual HDR reconstruction, original
working-gamut author textures, one LUT resource set, one fixed-scale analysis result and one
low-level node output. Analysis keys include source, tone/color/LUT, start and coverage;
strength/range/rolloff/enabled edits reuse it. Fused final frames are rendered on demand;
stripes allocate only stripe output textures, while source and fixed analysis remain resident.
`clearCaches()` releases these and CI intermediates. Source textures still obey Metal size
limits; tiled decoding and export memory admission belong to P7-3.

`ModelGainProvider` / `ModelGainPrediction` reserve P7-1b's boundary: infer original oriented
linear-P3 source once, cache by source/model identity, return a single-channel float log2 grid.
AI selections currently throw `aiNotAvailable`. P7-1b should inject that grid next to analytic
expansion, combine RAW captured/model by max, then reuse strength/range/rolloff and stripes.
Keep prediction independent of tone/color/LUT; explicit expansion-start masking belongs after
prediction, auto should preserve the model's result. No Core ML or model loading exists here.

## Verification

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and a private TMPDIR. Fetch
licensed RAW fixtures with `python3 scripts/fetch_test_fixtures.py`, then run `swift test
--package-path apps/apple/Packages/HyperDRRender`. Host Metal/codec access is required.

Thirteen focused tests cover the source contracts and each point operation, CPU-double LUT/
spatial analysis/offset references, tone anchors/white derivative, HDR-base invariance, rolloff
compensation, soft shoulders, fixed analysis reuse, resized stripes, repeated/new-context
renders and Apple-default RAW development/overrides. Comparisons use SDR/PQ 10-bit code
space (≤1 code) or tighter float checks for gain/metadata. Synthetic images and the licensed
RAW fixture are used; no tests reference user photos.

iOS device and simulator package targets build with signing disabled. Metal resources compile
at renderer creation; macOS tests exercise every new entry point. No App/Kit/engine is changed.

Apple M6, `taskpolicy -b`, with other builds running: synthetic 2560×1707 RAW-EDR gradient,
exposure +.3 EV, contrast +25, highlights −20, vibrance +20, captured + expansion. Three
cached-analysis frames take median 9.96 ms (8.98…11.35 ms), including allocation, submission
and GPU completion. First analysis takes 54.58 ms. Decode, source materialization, shader
compilation and CPU readback are excluded. These are shared-host measurements, not a device
performance guarantee; RAW decoding and iPhone inference should be profiled separately.

The JPEG decoder investigation remains in [Research/README.md](Research/README.md): the
approximately 14-code difference occurs before GPU processing; ICC contributes <.036 of a
10-bit code, and original Y/Cb/Cr IDCT planes differ by at most one 8-bit code, with additional
chroma interpolation/matrix/integer-rounding effects. System decoding remains authoritative.
