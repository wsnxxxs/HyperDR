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
preview and full development cannot alias. Both variants are retained together.
`rawSettings.nativeSize` preserves the oriented original size and `scaleFactor` records the
actual request. The shared `resolution` option also applies to ImageIO. Previews are
lower-resolution source approximations; preview/export share a fixed 1024-edge source
and 768-edge analysis, independent of the last loaded variant. Export must load `.full`
before rendering at export size rather than enlarging a preview texture.

Every RAW raster (native preview tiles, full development, export regions) must come back
opaque. Core Image's RAW decoder returns parts of some cropped regions transparent: on the lossy
DNG fixture, its last internal tile column (from x 4800) when a crop enters it from the column
before, always at some crops and now and then at others. `rasterize(opaque:)` counts transparent
texels on the GPU, renders a region again (three times), then splits it in two along its longer
side, recursively; a piece under 32 pixels that stays incomplete fails with `cannotDecodeSource`
rather than reading as black.

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

## Film emulation

`look.film` (`FilmAdjustments`) emulates Kodak Portra 400 and Gold 200 on Portra Endura paper,
Fujifilm Velvia 100 and Kodak Kodachrome 64 (slides, viewed directly) and Kodak Vision3 500T on
Kodak 2383, from spektrafilm's
measured stocks (CC BY-SA 4.0, Andrea Volpato). `scripts/convert_spektrafilm_stocks.py` bakes
each stock into `Resources/Film/<id>.json` and `<id>.spectral`: the Hanatos 2025 spectral
upsampling as a 192×192 float16 chromaticity table of film exposure (within a 10-bit code), the density curves (also before DIR couplers), the coupler
matrix, the 81-wavelength dye densities, enlarger and viewing light, the scanner's black and
white levels, and the grain's variance. `Film.metal` evaluates per pixel: linear P3 → film
exposure (Mitchell bicubic, as spektrafilm) → density with DIR couplers → grain → print exposure
and paper density (negatives) → viewed XYZ → scanner levels (paper white near display white) →
linear P3. `FilmStock.apply` is the double reference.

The film exposes the scene before the split, so HDR highlights reach its shoulder; its print is
the new SDR base and the gain is retained (L1); strength mixes in linear light. An applied film
develops RAW scene-linear, like a Log look, so Apple's tone curve is not applied twice. Tone and
colour edits act before the film, as changes to the scene it photographs.

`look.filmExposure` is the film's exposure compensation. Auto (`RenderEngine.filmMeter`) is
spektrafilm's centre-weighted meter: luminance weighted by a Gaussian of sigma 0.2 of the long
edge, put at 18.4 %, clamped to the declared ±3 EV. It meters the original photo on the fixed
analysis source, before any edit, so preview and export agree and the light edits still move the
exposure; `resolvedAutomatic` reports it.

Grain (`look.filmGrain`, 100 % = the stock's own) follows spektrafilm's sublayer particle model,
with a 35 mm frame spanning the render's long edge. Per channel, each of the three sublayers
develops Poisson particle counts: its density variance and third cumulant against density, per
pixel area, are tabulated. Each sublayer's dye clouds (0.5–1.7 µm, a size on the film) and then
the scan (0.65 pixels) blur its particles, both sampled as spektrafilm's FIR blurs. The render
draws one field of hashed unit noise per channel (Box–Muller, one hash per pixel), puts it
through the sublayers' kernels mixed by their variance at the pixel's density, scales it to the
variance the separately blurred sublayers give, and bends it (Cornish–Fisher, solved exactly) to
their third moment. The kernels depend only on the pixel pitch, so `FilmStock.packedGrainKernel`
computes them once per render, cut where no tap reaches 5 % of its centre (3×3 at ordinary sizes,
wider once dye clouds span pixels, as at 110 MP); the variance and third moment come from the
whole kernels. Grain never takes density below minus the stock's minimum density, as particles
counted above it cannot. The noise hashes output pixel coordinates, so regions and stripes of a
render agree; analysis cells are grainless.

In-emulsion scatter is part of the stock, as in spektrafilm: film exposure is blurred by an
energy-preserving mixture of a Gaussian core (about 2 µm) and an exponential tail (about 9.5 µm,
spektrafilm's three-Gaussian fit), per channel. It softens edges and makes very bright points bloom.
It is computed at the render's own resolution: `graphFilmExposure` evaluates the film exposure of
the region plus `FilmAdjustments.sourceHalo` pixels (three of the widest sigma), `filmBlur` runs
the separable passes (half floats, scipy's reflected edges), and `graphOutput` reads the result in
place of its own exposure. Sources cropped for a region (export tiles, the editor's detail regions)
are materialized with that halo, so tiles and regions match the whole render exactly; export tiles
shrink by the halo to stay within the source tile limit. Below about 220 pixels on the long edge
its taps round to the centre alone and the pass is skipped.

Halation (`look.filmHalation`, 100 % = the stock's own; `look.filmAntihalation` off uses
spektrafilm's strengths for a film without its antihalation layer, as CineStill does to Vision3)
is back-reflected light: the scattered film exposure plus strength × a sum of three Gaussians
(sigma 65 µm for still film, 50 µm for motion picture, × √k, weights halving), divided by 1 +
strength. The glow is low-frequency, so analysis integrates each cell's film exposure over its exact
footprint (`graphFilmCells`) and blurs that map with the same separable passes. The render samples
it with a cubic B-spline, so preview, export, regions and stripes share it; the map's sigma is
widened by the scatter's variance and narrowed by the cells' and the spline's (1/12 + 1/3 cell²,
`FilmStock.halationMapComponents`). At a 6000-pixel render (eight pixels per cell) the glow is
within 3 % of the stock's halation computed at full resolution. Glare and other spatial effects
are not modelled.

Tests compare the double reference with spektrafilm's per-pixel outputs, HDR inputs included
(`Fixtures/film-reference.json`, within a 10-bit code), the grain with spektrafilm's stochastic
grain at 91, 6, 3 and 1.5 µm pixels (RMS < 5 %, skewness and neighbour correlation), the halation profile across a bright square with spektrafilm's (within 1e-3 of the
square; spektrafilm's recursive blur approximates the far tail), its scatter (1e-5), the GPU with
the double reference, grain, scatter and halation included (≤ 1 10-bit code), regions and export
tiles with the whole render (exactly), and full-size halation as above.
## Caches, limits and P7-1b

The engine retains full and the latest preview for one asset/development family, plus a
fixed 1024-edge analysis source, optional dual HDR reconstruction, original working-gamut
author textures, one LUT resource set, one fixed-scale analysis result and one node output. Analysis keys include source, tone/color/LUT, start and coverage;
strength/range/rolloff/enabled edits reuse it. Fused final frames are rendered on demand;
stripes allocate only stripe output textures, while source and fixed analysis remain resident.
`clearCaches()` releases these and CI intermediates. Source textures still obey Metal size
limits; tiled decoding and export memory admission belong to P7-3.

`ModelGainProvider` / `ModelGainPrediction` reserve P7-1b's boundary: infer original oriented
linear-P3 source once, cache by source/model identity, return a single-channel float log2 grid.
AI predictions enter alongside analytic expansion, combine RAW captured/model by max,
then reuse strength/range/rolloff and stripes. Prediction and guided reconstruction remain
independent of tone/color/LUT; explicit expansion-start masking follows prediction, while
auto preserves participation. Core ML supplies the original unsmoothed grid.

## Verification

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and a private TMPDIR. Fetch
licensed RAW fixtures with `python3 scripts/fetch_test_fixtures.py`, then run `swift test
--package-path apps/apple/Packages/HyperDRRender`. Host Metal/codec access is required.

Focused tests cover the source contracts and each point operation, CPU-double LUT/
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


R1 model gain integration

```swift
// First render is useful immediately; its aiPending flag is true.
let pending = try await engine.render(source, recipe: aiRecipe)
let prediction = try await engine.predictModelGain(source, provider: provider)
let ready = try await engine.render(source, recipe: aiRecipe, modelGain: prediction)
```

`RenderAdjustments.hdr.modelGain` accepts the same prediction for direct-adjustment
calls. Recipe render and stripe entry points accept `modelGain: ModelGainPrediction?`.
The caller schedules inference and triggers the next render; rendering never starts
an implicit task or waits for Core ML. `RenderPlanes.aiPending` marks active AI
selection without a prediction. Disabled HDR does not wait for AI.

`predictModelGain(_:provider:)` uses `predict(source:)` for SDR and
`prediction(forSDRBase:sourceID:size:)` for RAW, with `sdrBase(_:)` returning the
untouched source separation (zero SDR highlight rolloff). HDR/dual inputs reject AI.
Prediction identity/cache is `(sourceID, modelID)`; modelID includes preprocessing
and analysis scale. Treat the gain texture as immutable for this identity.

The HDR node upsamples onto the fixed guide, suppresses negative highlight gain,
applies optional explicit-start participation, then uses a guided filter (epsilon
.005, radius 4–8 analysis pixels) bounded by each pixel's prediction. Default auto
start does not gate the model. Filter cache excludes light/color/LUT and retains
source/model/start identity. Captured/model gain combines by maximum; strength,
range soft shoulder, SDR rolloff compensation and HDR enable apply afterward.
`DoubleReference.modelGain` provides the guided-postprocess double reference.


R4–R8 editor support

```swift
let options = RenderOptions(bypassedGroups: [.light])
let sourceOptions = try SourceOptions(recipe: recipe, resolution: resolution, options: options)
let source = try await engine.load(url, options: sourceOptions)
let frame = try await engine.render(source, recipe: recipe, options: options, size: size)
let automatic = try await engine.resolvedAutomatic(source, recipe: recipe, options: options)
let mask = try await engine.effectMask(source, recipe: recipe,
                                      parameterID: "tone.highlights", options: options,
                                      size: size, region: region)
```

Loaded variants share `RenderSource.id` for source/model identity, while separate
internal render identities prevent preview/full GPU caches from aliasing. Statistics
and model input reopen the same asset/development at a fixed 1024 longest edge (no
upscale), then use the existing fixed 768 analysis grid. Source origin travels with
the source so a different RenderEngine computes the same analysis. Preview/full
switches keep statistics and predictions; changing file revision or RAW settings
starts a new source family. One full, one latest preview and one analysis source
bound internal residency. Synthetic/already-decoded sources use their supplied pixels.

`RenderOptions.bypassedGroups` is ephemeral. Light/color/look bypass removes their
edits; RAW color/detail bypass restores camera/Apple defaults. Pass the **same options
to SourceOptions and rendering** so RAW bypass redevelops when needed. HDR bypass
turns off HDR output and SDR rolloff. Recipe is never mutated or persisted with bypass.

`resolvedAutomatic(_:recipe:lut:modelGain:options:)` returns `[String:Double]` in
Recipe units: `hdr.range` in stops; analytic `hdr.expansionStart` in percent. It
returns only values currently automatic, and omits an AI auto start because that
means no numeric participation gate. Imported HDR/dual auto range retains source
headroom (up to four), while generated SDR/RAW range is capped at three.

`effectMask(_:recipe:parameterID:lut:modelGain:options:size:region:) -> RenderMask`
returns R32Float participation in [0,1] and ROI/output-size metadata. Highlights,
shadows and blacks use the actual luminance before that light node. Participation
and coverage show the fixed-grid eligible region; AI auto participation is one.
`gain` shows positive decoded gain divided by headroom, and `gainFull` shows whether
positive gain exists. Inactive/bypassed operations return zero. Unsupported mask ids
throw `invalidAdjustment`; there are no UI/color-map dependencies.

`RAWDevelopment.sourceValues: [String:Double]` holds **pre-override defaults** in
Recipe units: temperature Kelvin, neutralTint −150…150 directly, NR and sharpness
0…100 percent. Existing applied scalar fields remain CIRAWFilter units (NR/sharpness
0…1). `capabilities: Set<String>` uses the exact declaration capability strings.
Use these dictionaries directly for AdjustmentContext; neither NR double conversion
nor tint division by 100 belongs in the editor.


`sourceReport(_:) -> SourceReport` supplies editor-facing source facts:
`sourceValues: [String:Double]` and `capabilities: Set<String>` both use Recipe
parameter IDs. `hdr.range` is the original source capacity in stops from the
unedited fixed-scale analysis; RAW `tone.exposure` is the file's baseline exposure,
not a user adjustment. RAW camera/Apple defaults are included in Recipe units.
Capabilities filter the declaration's input domain and actual RAW support;
current visibility/selection is separate. The lower-level
`RAWDevelopment.capabilities` retains its CIRAWFilter predicate names for callers
that evaluate declaration conditions. `resolvedAutomatic` separately reports the
actual edited auto output range as `hdr.range`.

AI predictions use a four-entry LRU keyed by `(sourceID, modelID)`. Switching
development families preserves these small grids; `clearCaches()` removes them.
`ModelGainError.deviceUnavailable(String)` identifies absent Metal/Core ML compute
devices. Missing/broken model resources remain `modelUnavailable`; inference failures
remain `predictionFailed`. These are not labelled as hardware incompatibility.

RAW preview `SourceOptions(recipe:resolution:)` sets CIRAWFilter.scaleFactor
before requesting output; it never develops a full-size image first. `.full`
remains the export policy.


File-backed sources bind their size/modification-date revision at load. Lazy
fixed-scale analysis validates that revision before and after decode (with URL
resource-value caches cleared). Replacing the file cannot attach new analysis or
AI input to an old source ID: a required reopen throws `RenderError.sourceChanged`.
Already cached analysis and materialized pixels remain usable; after cache clear
or transfer to another engine, the editor must reload a changed source.

### Export handoff (P7-3b-R)

`ExportTypes.swift` fixes the Kit/Fake boundary for the RenderEngine
implementation and backend Fake. `ExportStripeRendering.renderExportStripes` receives a
source, the frozen Recipe/LUT/model prediction, and `ExportRenderRequest`.
It calls `prepare(ExportRenderReport)` once with the final metadata, then
`consume(ExportStripe)` for each top-down band, and returns that same report.
Both callbacks are synchronous and throwing; retain CPU arrays as needed, do not
queue unbounded bands. A failed operation leaves partial bands to discard.
RenderEngine conforms directly. It never writes files or calls an encoder.

`photoSize` is the destination-limited photograph, before adding a frame.
`FrameSnapshot` carries the final canvas and integral photo rectangle, linear-P3
paper colour, shadow sigma/offset in final pixels, and optional straight-alpha
Display-P3 caption PNG with its final rectangle. Compute layout and text in the
caller, convert the paper's UI colour to linear P3, and freeze PNG bytes before
starting. No UI objects cross this boundary.

`ExportPairCapabilities` describes the selected format/depth: RGB gain, nonzero
offsets, signed gain and Apple-style maximum-gain headroom constraints. It is
not an encoder selection enum. C ABI 4 only supports P3 gain working space;
unsupported workspaces require exact reconstruction/resplit, reported in
`resplitReasons`. Destination gamut is an output conversion declaration:
CPU base planes always remain **linear P3 RGB float32**, gain planes decoded
**log2 float32** on the same canvas grid, for the C ABI to consume.
`includesGain=false` is for SDR-only output; PQ/HLG still need gain to reconstruct
HDR even though their file does not store an auxiliary map. `rows` is explicit
(256 recommended); it bounds Render bands, not b-stage whole-plane accumulation.

Kit owns durable Recipe/source/LUT/frame fingerprints, model waiting, memory
admission, file output and reporting. These Render inputs contain no paths,
PhotoKit assets, platform views, export history or screen headroom adaptation.


The export implementation scans photo bands first to determine one global header
(channel count, signed gain, transparency, HDR peak), then emits bands. This is
bounded GPU readback with two render passes, not a file writer or full-source
streaming. `prepare` follows the scan, before any pixel callback. Intermediate
textures are recycled per band; b-stage Kit still owns whole-plane accumulation.
Generated metadata uses the global maximum, never the first band's maximum.

`ceilingStops` only narrows the resolved recipe range via the existing soft
shoulder. A remaining overflow after ICC reconstruction uses the same shoulder;
max-channel base is chosen **before** reducing gain. Unsupported RGB gains,
offsets, signed gain, non-P3 working gamut, Adaptive headroom, and unequal framed
offsets are reconstructed with ISO vector math and re-separated. Report reasons
include `flattenTransparency` and `outputCeiling` as well as the six original
capability reasons. The legacy black-alpha rule is retained (see codec's
`internal/cicp.hpp`): composite after ISO reconstruction. Zero-offset simple
pairs can retain their gain while their base is multiplied by alpha.

Frame pixels use only linear-P3 paper, Gaussian print shadow and a decoded caption
PNG. Text alpha blends in linear light (the planned GPU convention, unlike the
old encoded-space text blend). Gain outside the photo rectangle is exactly zero;
Kit must still pass presentation_frame for E5 quantization and, on gain-map output,
frame_photo for E5 readback. Render does not quantize gain or alter its codebook.

File-backed `RenderSource.id` is a SHA256-derived UUID over canonical path, file
size/modification-date revision, decoder choice, lens correction and normalized
engine-unit RAW values (including signed-zero normalization). Preview dimensions
are omitted. Returning to the same settings, clearing pixel caches, or loading in
another engine yields the same ID; a different revision yields a different ID.
Only one development family's full/preview/analysis pixels are resident internally;
small AI predictions survive a family switch for the last four source/model keys.


### Lazy export sources (P7-3d-R)

`await engine.openExportSource(url, options:) -> ExportSource` opens full-quality
ImageIO/Core Image or CIRAWFilter graphs without creating a full-size Render
RGBAf texture. It materializes a fixed 1024-long-side `analysisSource`, which is
also the source to pass to `predictModelGain`. The source exposes stable `id`,
`domain`, `nativeSize` and `rawSettings`. Keep security-scoped file access alive
through export. File revision is checked when opening and before/after each ROI;
a replaced source throws `sourceChanged`.

`renderExportStripes(ExportSource, recipe:lut:modelGain:request:rows:prepare:consume:)`
has the same report and callbacks as the materialized overload. Each scan/output
band materializes its native-pixel source ROI with two sampling-support texels;
Core Image requests upstream filter halos. Auxiliary gain is cropped on its own
native grid, decoded before display resampling. Global pixel-space bilinear
weights avoid the dimension-dependent rounding of hardware normalized samplers.
Analysis remains fixed-scale, shared across bands. Export still scans once before
emission to determine global metadata. No writer or package behavior changes.

Opening clears engine-owned pixel caches, keeping the last four AI predictions.
Use a separate export engine to keep editor preview caches warm. Render owns
only analysis, band textures and bounded readback. This does **not** promise
region-only codec I/O or bounded Apple internal caches: ImageIO may decode a full
compressed image; CIRAWFilter/Core Image/Metal can retain full-frame workspaces.
Kit's whole-plane accumulation also remains until incremental writing lands.

Measured on the licensed 2768×1848 Sony RAW, separate fresh macOS test processes,
full-size export, 256-row bands, discard-on-consume (no writer accumulation):

| Measurement | Materialized source | Lazy source |
| --- | ---: | ---: |
| Physical footprint after open | 431,981,552 B | 250,823,640 B |
| Kernel lifetime peak physical footprint | 636,322,992 B | 389,497,960 B |
| Physical footprint after clearCaches | 165,708,952 B | 149,242,960 B |
| Open + two-pass render time | 3.60 s | 3.19 s |

`TASK_VM_INFO` measures physical footprint, including unified GPU allocations;
its lifetime peak includes transient peaks between callbacks. Lazy peak is 38.8%
lower, but remains much larger than its ~11.5 MB full-width source band and
~11.2 MB analysis image. These observations establish internal framework/cache
cost; they do not isolate CIRAWFilter bytes or establish safety for 61MP/iPhone.
Repeat explicitly with `HYPERDR_EXPORT_MEMORY_PROBE=full` or `stream` and
`swift test --filter ExportSourceTests.rawMemoryProbe`, one fresh process each.
The ordinary suite skips this measurement. Functional tests compare oriented
raster, authored gain pairs and RAW ROI/resized exports against whole-source
rendering within one normalized 10-bit code; gain uses the 0–4-stop code range.
Export reports distinguish the rendered `sourceProvenance` from final
`provenance`. `rangeBeforeCeiling` / `rangeAfterCeiling` are resolved stops;
`ceilingApplied` says the output ceiling narrowed that range. This upstream H3
adjustment does not require a resplit and is reported even when `resplitReasons`
is empty. A later output-boundary conversion still records `.outputCeiling`
among its actual resplit reasons.
