# HyperDRRender

Shared macOS 26 / iOS 26 GPU processing, without AppKit, UIKit, C ABI or C++ interop.
HyperDRRecipe's `Adjustments` owns parameter declarations, defaults, ranges, units and typed
visibility conditions. Render reads this catalogue; it declares no copies of HDR range or RAW
lens correction. `RenderAdjustments(recipe:lut:)` and `SourceOptions(recipe:)` resolve Recipe v1
into GPU/RAW values. Full-frame and stripe APIs also accept `recipe:` directly.

```swift
let renderer = try RenderEngine()
// For a restored recipe, pass SourceOptions(recipe:) when loading RAW.
let source = try await renderer.load(url) // caller holds the security scope
var recipe = Recipe(inputDomain: source.domain)
recipe.setValue(.number(0.25), for: "tone.exposure")
let preview = try await renderer.render(source, recipe: recipe,
    size: PixelSize(width: 2560, height: 1707))
try await renderer.renderStripes(source, recipe: recipe, rows: 256) { stripe in
    // Consume textures or RenderEngine.readPixels(stripe), then release them.
}
```

Numeric conversion happens only in `ParameterDeclaration.engineValue`: percent and signed
levels become 0…1 / −1…1; contrast becomes `1.6^(value/100)` (−100 → .625, 0 → 1, +100 → 1.6).
EV/stops/kelvin and RAW tint stay unchanged. GPU kernels and DoubleReference consume resolved
engine units; they do not repeat UI conversion. The direct `RenderAdjustments`/`AdjustmentNode`
APIs use these engine units too. Nil range/start resolve auto using Recipe's
`generatedRangeCeiling` and `automaticExpansionStart`; nil RAW amounts preserve Apple defaults.
HDR source defaults come from Recipe's domain rules, including `builtIn` for HDR/dual.

Resolve `recipe.look` by its content hash and pass the resulting `ColorLUT` as `lut:`. The hash
is SHA-256 of the original .cube bytes; Render validates the match. A disabled/zero-strength LUT
can remain unresolved. An active missing/mismatched LUT reports `invalidLUT`, avoiding silent
look loss. Equal LUT contents share identity/cache keys even after reparsing. Security-scoped
bookmark resolution stays with the caller.

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
Changing these options invalidates the development cache. Export defaults to
`RAWResolution.full` (scale 1). Preview uses
`SourceOptions(recipe: recipe, rawResolution: .preview(maximumSize: canvasPixelSize))`;
CIRAWFilter scales development to fit that oriented canvas without upscaling. Both paths keep
Apple detail defaults and disable draft mode. Resolution is part of the source cache key, so
preview and full development cannot alias; the cache still retains just one developed source.
`rawSettings.nativeSize` preserves the oriented original size and `scaleFactor` records the
actual request. Raster formats ignore this RAW option. Previews are lower-resolution source
approximations; preview/export still use the same graph and fixed 768-edge analysis, with
analysis cached separately for each developed source. Export must load `.full` before rendering
at export size rather than enlarging a preview texture.

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
Low-level node graphs allow at most one `SourceHDRSplitNode`; both full-frame and stripe
entry points reject duplicates with `RenderError.duplicateHDRSplit` before rendering.

* HDR/RAW/dual exposure and negative SDR exposure are linear `2^EV`. Positive SDR exposure
  uses a moving shoulder: K=2^EV, k=K^-2 in original luminance x; below k, f=Kx; above k,
  `f=1-(1-1/K)*((1-x)/(1-k))^(K+1)`. White stays 1. The two branches join with derivative K;
  the derivative at white is zero, matching the bounded white extension. The shoulder is
  monotone, below 1 for x<1, and f≥x throughout SDR [0,1] (the upper branch minus x is concave
  with nonnegative endpoints). As EV→0+, k→1 and f→identity; exactly zero bypasses unchanged.
  This replaces the fixed .48 knee that could darken highlights for infinitesimal exposure.
* Contrast receives Recipe's multiplier c=.625…1.6. Below .18 it uses AE-3's power.
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
  Every declared input/output combination is supported, with S-Log3 input restricted to RAW.
  Encode to the input space → clamp/sample the .cube domain → decode from output to linear P3.
  SDR-input/SDR-output LUTs act on the separated base and retain its gain unchanged (L1).
  SDR-input/HDR-or-Log-output LUTs also act on the base, then multiply by the original gain
  and resplit; their output can create HDR. HDR/Log-input LUTs act on the whole HDR image
  before separation. Strength mixes original and transformed RGB in linear light at the
  corresponding stage; zero bypasses conversions. 3D interpolation uses explicit float
  trilinear reads. L1 gain/ratio retention applies to our zero-offset split pairs.
  Any active light/color/look edit on a dual source first crosses the authored-pair boundary:
  reconstruct the author's HDR, split in linear P3, then apply the look to that new pair;
  provenance is `resplit`. Only unedited and HDR-only dual edits retain authored gain/offsets.
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
  Modified-strength/expansion gating uses a conservative gain bound. Captured strength 1
  gates using the actual transformed HDR peak, leaving pairs already within range unchanged.
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

Nineteen focused tests cover the source contracts and each point operation, CPU-double LUT/
spatial analysis/offset references, tone anchors/white derivative, HDR-base invariance, rolloff
compensation, soft shoulders, fixed analysis reuse, resized stripes, repeated/new-context
renders, Apple-default RAW development/overrides and the Recipe/default/unit/LUT boundary.
The exposure contract checks identity, EV continuity, no darkening, monotonicity, bounded white
and its derivative independently of the GPU/double equality. One pixel/LUT/strength covers
all declared LUT space pairs, using SDR except where S-Log3 input requires RAW (no additional
domain or image matrix). Comparisons use SDR/PQ 10-bit code
space (≤1 code) or tighter float checks for gain/metadata. Synthetic images and the licensed
RAW fixture are used; no tests reference user photos. Preview checks cover ROI/full-frame
agreement, SDR thumbnail orientation, tiered ImageIO/RAW resolution, and PQ/dual preservation.
Display checks cover native-gamut three-channel ISO gamma/offsets at endpoint and intermediate
weights, decode-before-resample, legacy system reconstruction, and unchanged export planes.

iOS device and simulator package targets build with signing disabled. Metal resources compile
at renderer creation; macOS tests exercise every new entry point. No App/Kit/engine is changed.

Apple M6, `taskpolicy -b`, with other builds running: synthetic 2560×1707 RAW-EDR gradient,
exposure +.3 EV, contrast +25, highlights −20, vibrance +20, captured + expansion. Three
cached-analysis frames take median 9.96 ms (8.98…11.35 ms), including allocation, submission
and GPU completion. First analysis takes 54.58 ms. Decode, source materialization, shader
compilation and CPU readback are excluded. These are shared-host measurements, not a device
performance guarantee; RAW decoding and iPhone inference should be profiled separately.

RAW check after R13 on the licensed fixture, same M6/background process, both outputs 2560×1707:
full development is 2768×1848, decode/materialization 418.37 ms plus first graph 47.47 ms
(465.83 ms total); preview development is 2557×1707, decode/materialization 366.44 ms plus
first graph 49.05 ms (415.49 ms total). These are one sequential full-then-preview measurement,
not cold-start comparisons. Graph times include first fixed-scale analysis and GPU completion;
shader setup, fixture copying, encoding/writing and CPU readback are excluded. The fixture is
only 5.1 MP, so its canvas-sized development reduction is modest.

The JPEG decoder investigation remains in [Research/README.md](Research/README.md): the
approximately 14-code difference occurs before GPU processing; ICC contributes <.036 of a
10-bit code, and original Y/Cb/Cr IDCT planes differ by at most one 8-bit code, with additional
chroma interpolation/matrix/integer-rounding effects. System decoding remains authoritative.


P7-2b preview interfaces (R2/R9)

```swift
// Region is optional: integral output pixels, top-left origin, contained in size.
try await engine.render(source, recipe: recipe, lut: lut, size: outputSize, region: region)
let resolution = try SourceResolution.preview(canvasSize: canvasSize, nativeSize: nativeSize)
let source = try await engine.load(url, options: SourceOptions(recipe: recipe, resolution: resolution))
let thumbnail = try await engine.sdrThumbnail(planes, maximumSize: PixelSize(width: 512, height: 512))
```

`SourceResolution` covers both RAW and ImageIO; `RAWResolution` remains a type alias.
The canvas tier helper selects 1280 / 2048 / 2560 / 3840 without upscaling the source.
`RenderSource.size` is the decoded size; `nativeSize` is the oriented file size.
ImageIO previews use decoder thumbnails before RGBAf texture allocation, retaining
HDR decoding for single HDR assets and the original SDR rendition for dual assets.
Full resolution remains the default for export. Thumbnails read only the SDR base,
convert its native gamut to Display P3, and never bake gain into the thumbnail.
ROI rendering uses the same global analysis as a full frame.


P7-2b display pair (R3)

```swift
let display = try await engine.displayPair(planes, source: source) // DisplayGainPair
```

`DisplayGainPair` exposes `base` (RGBA32Float, linear P3), `gain` (R32Float or
RGBA32Float decoded log2), `gainChannelCount`, `baseOffset`, `alternateOffset`,
`baseHeadroom`, `alternateHeadroom`, `p3ToGain`, `gainToP3`, `region`, `outputSize`,
and computed `size` / `isSimpleGain`. The public initializer accepts these fields
so editor fakes can build frames without decoding an asset. Headrooms are **log2
stops**, not luminance multipliers. Matrices are `simd_float3x3`, column vectors,
matching Metal's matrix layout. A one-channel gain uses its red value for all RGB.
Sample native-resolution gain using normalized coordinates within the displayed
region. `size` is the actual ROI texture size; `outputSize` is the full requested
canvas, and `region` locates that ROI in the canvas.

For any ISO weight `w`, the compositor computes:

```
gainToP3 * ((p3ToGain * base + baseOffset) * exp2(w * gain) - alternateOffset)
```

Render decodes ISO min/max/gamma **before** gain interpolation, retains ISO offsets
and both headrooms, and obtains ICC matrices through Core Image/ColorSync in linear
light. Legacy Apple files use the system's full HDR reconstruction and exact
per-channel inversion into a display-only ISO pair, with equal 1/64 offsets to
represent black safely; their native encoded gain remains untouched for export.
Generated zero-offset P3 pairs reuse both textures and identity matrices
(`isSimpleGain`); no ICC/gamma work belongs in the compositor. A deterministic GPU
reduction supplies missing alternate headroom. The original `RenderPlanes`, its
native base gamut, encoded gain bytes, and auxiliary metadata remain the export
input and are never replaced by `DisplayGainPair`.

R3 timing on the same shared M6 host: normalizing a generated 2560×1707 pair took
0.60 ms in one pass (includes the GPU peak reduction and command completion;
identity matrices and both textures were reused). This excludes any ICC setup
or native ISO/Apple decoding and is not an iPhone performance measurement.
