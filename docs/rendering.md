# Rendering and compatibility guarantees

What the renderer promises about its output, and the manual gate a release still
has to pass. For the options that drive it see
[cli-reference.md](cli-reference.md); for what a run records see
[report-schema.md](report-schema.md).

The primary render contract is now `PhotoRenditions`: an SDR image and an optional
HDR image in linear Display P3. SDR JPEG writes only the SDR rendition. HLG/PQ
encoders consume the HDR pixels directly; the gain-map quantization and
reconstruction guarantees below apply to Adaptive HDR, Ultra HDR, and model gain
adapters. Creative LUT placement and its effect on these guarantees are described
in [colour LUT pipeline](color-lut-pipeline.md).

## Input domains

Three kinds of input reach the renderer, and they are not interchangeable. The
decoder records which one it produced, in `DecodedImage::domain`; the report
carries it as `input_domain`. Nothing branches on the file extension.

| Domain | Produced by | What 1.0 means | Renderer |
| --- | --- | --- | --- |
| `scene-referred` | RAW through LibRaw | wherever white balance landed | photographic curve, automatic exposure |
| `display-referred-sdr` | JPEG, PNG, SDR HEIC/AVIF, an Ultra HDR JPEG that fell back to its primary | diffuse white, and the ceiling | stable finished base plus creative highlight gain |
| `display-referred-hdr` | PQ/HLG HEIC and AVIF, Ultra HDR, a gain-map HEIC | diffuse white, with real detail above it | log-domain shoulder, split at the declared headroom |

PNG, HEIF and AVIF transparency is composited onto black in linear Display P3
before resizing or rendering; outputs are opaque photographs. Premultiplied
inputs are first unassociated in their encoded colour space, then converted to
linear light and weighted by alpha. An Adaptive HDR HEIC reconstructs its HDR
pixels before applying alpha, because gain-map offsets do not commute with
compositing. Fully transparent pixels become exactly zero, irrespective of
their hidden RGB values.

- **A scene-referred input** is developed: the photographic curve below chooses
  an exposure from the scene's log average and selects headroom from content.
- **A display-referred SDR input** is already a finished photograph, so it does
  not get automatic exposure or pretend that its container carried highlight
  data. Its base uses the same exposure and roll-off at every HDR strength,
  including zero. A smooth highlight gain above the knee lets `--gain-strength`,
  `--headroom`/`--headroom-max`, `--expansion-start`, and `--area-coverage`
  create a controlled HDR alternate for ordinary JPEG/PNG photos. The source
  remains labelled SDR; the inferred range is a creative output budget, not an
  input measurement. Explicit exposure and exposure bias are both honoured;
  capture ISO participates in local noise weighting. The panel keeps `pop`
  fixed so its strength slider does not also change clarity and colour.
- **A display-referred HDR input** is split rather than re-developed. Both
  renditions come from one shoulder in the log domain: identity below the knee
  (`--expansion-start`), slope exactly 1 at the knee, and asymptotic above it.
  The ceiling is the only difference between the two. Each ceiling is *solved*
  so the input's declared peak lands exactly on its target — 1.0 for the base,
  the output headroom for the rendition — because a shoulder only approaches
  its ceiling, and assuming it instead rendered a 1.06-stop input at 0.42 stops.
  When the output budget covers everything the input declared, the rendition is
  the input, unmodified.
- PQ/HLG PNG, HEIF and AVIF may declare MaxCLL independently of the transfer
  function's capacity. Tone mapping uses that nonzero content peak, bounded by
  the encoding capacity and a minimum of SDR white (203 nits), before exposure.
  Transfer decoding and the HDR input domain stay unchanged. Thus a 203-nit PQ
  photograph has no HDR range to compress or expand, rather than being mapped
  as though it reached 10,000 nits. Missing/zero MaxCLL retains the encoding
  fallback. This is a declared mapping hint, not a rescaling of pixel light.
- The output headroom is the input's declared headroom capped by
  `--headroom`/`--headroom-max` and scaled by `--gain-strength`, so an
  over-range input is attenuated deliberately instead of being flattened
  against the format ceiling. Because ISO 21496-1 metadata declares the gain
  interval as the alternate headroom, this is also what makes re-export stable:
  a gain-map HEIC round-trips at 2.08x across passes, drifting only by 8-bit
  gain quantization, where it previously lost roughly a third of its range each
  time.
- For Adaptive HDR and Ultra HDR the HDR rendition of an HDR input is packaged
  to decode back to itself, pixel for pixel. The gain map is full resolution,
  so no decoder resamples it: libultrahdr, Core Image and this project each
  interpolate a smaller map by a different rule, and averaging gain over cells
  gave every highlight its darker neighbours' gain (a Sony HLG frame came back
  about a fifth darker above diffuse white). Each pixel's gain is the larger of
  the SDR tone map's luminance ratio and the ratio that brings its brightest
  channel down to 1.0, capped at the rendition's headroom; codes are rounded up
  and the base is then computed from the *decoded* gain, so `base × 2^gain` is
  the HDR pixel again and the 8-bit gain step only darkens the base by at most
  one code (0.6% at 2.3 stops). The base therefore carries the HDR pixel's own
  chroma instead of a gamut-fitted SDR colour — a saturated light is darker in
  SDR rather than paler in HDR. The cap keeps `alternate_headroom` at the
  photograph's real luminance range, because every display with less headroom
  scales all gain by headroom ÷ `alternate_headroom`; a colour whose brightest
  channel exceeds that range (0.04% of the reference HLG frame) keeps its
  luminance and gives up only the excess chroma. A pixel below the knee receives
  gain only when one of its channels is brighter than SDR white, which is what
  `render.below_knee_relative_difference_max` then reports.
- A full-resolution gain map larger than 3072 pixels an edge is written as a
  grid of 2048-pixel HEVC tiles in the same layout as the base; the Ultra HDR
  base of a full-resolution map is coded 4:4:4 rather than 4:2:0, because that
  map exists to restore pixel-level detail and subsampled chroma measured as most
  of the remaining error at saturated highlight edges. The panel exports an HDR
  source's Adaptive HDR base at 10 bits; on the reference HLG frame an 8-bit
  base was the largest remaining loss. `HyperDR verify <output> --reference
  <source>` measures what survived (see [cli-reference.md](cli-reference.md)).
- HLG uses the luminance-based BT.2100 OOTF. Its encodable display-light volume
  is not a fixed RGB cube: with display RGB normalized to 1000 nits and
  luminance `Y`, each channel must be at most `Y^(1 - 1/1.2)` for the inverse
  OOTF's scene values to fit [0, 1]. Colours beyond that boundary are moved
  toward the same-luminance neutral before encoding. This preserves brightness
  instead of clipping saturated highlights channel by channel. Colours already
  inside the HLG volume are unchanged. HEIC, AVIF and HLG LUT input encoding
  share this handling; a colour outside that volume cannot retain all of its
  saturation in a bounded HLG signal.
- For RAW and SDR inputs, and for renditions whose SDR endpoint carries its own
  LUT grade, the gain a cell carries is the mean of the gain its own pixels ask
  for, with below-knee pixels contributing zero — the gain map downsampled,
  rather than the gain of the downsampled image, so a small specular is not
  averaged away before it is ever restored. Because the grid is then sampled
  bilinearly, a shadow pixel bordering a bright cell still receives a little
  gain; the report measures exactly how much as
  `render.below_knee_relative_difference_max`. Manual rendering retains this
  pixel selection through LUT grading. For gain-map output, peak, utilization and
  below-knee difference are measured from the final quantized, reconstructed
  map, before JPEG/HEVC compression; they are not measurements of the codec's
  additional loss.

Working in the log domain is what makes a large input headroom usable. A
linear-domain shoulder asymptotic to 1.0 spends nearly its whole output range
on the first two stops: a PQ input reaching 49x diffuse white arrived at the
8-bit base with everything above roughly 1.5x sharing the top two code values.
The log-domain shoulder spreads the same 5.6 stops across roughly 26 codes at
the default knee, and leaves everything below the knee bit-exact.

The headroom the split uses is the one the *container declared*, never a
percentile of the pixels. An HDR file whose colour is described by an ICC
profile rather than by CICP therefore reports SDR; it has no measured input
headroom, but the output controls may still apply the same fixed-exposure
creative expansion as any other SDR photograph.

## Guarantees

- The photographic path uses a shared toe and middle segment for SDR and HDR.
  Their exponential shoulders asymptote to `1` and `2^headroom_stops` rather
  than hard-clipping highlights. Scene-referred input selects exposure
  automatically; display-referred SDR retains its finished base and builds
  creative gain separately.
- A single-channel gain map can only reconstruct a common RGB multiplier. Shared
  vibrance, highlight-to-white convergence, and hue-preserving gamut compression
  therefore happen on the shared base. RAW chroma is determined by SDR
  luminance, independent of the strength of the HDR alternate.
- Every gamut fit (the shared base, display-referred SDR and HDR renditions,
  the base of an exact HDR gain map, and the sRGB cube of an sRGB output) keeps
  the colour's luminance, gives up only saturation, and returns a colour already
  inside unchanged. Which hue it keeps depends on the hue. Outside the blues and
  violets the colour keeps its Oklab hue: a straight line toward neutral keeps
  the xy dominant wavelength, and on narrow-band LED colours that line missed
  the hue of reds, oranges and yellows by 7.7 degrees on average in CAM16, 13.0
  in IPT and 15.5 in ICtCp, against 1.7, 7.0 and 6.5 along the Oklab hue, and it
  drew pink cores into orange lights. Blues and violets (Oklab hue -150 to -60
  degrees, blended over 20 degrees on each side) keep the straight line: there
  the four models disagree by up to 20 degrees, and the Oklab hue turned a blue
  light in a real night frame teal where the camera's own rendering is blue.
- Gain maps write zero base and alternate offsets, preserving common RGB ratios
  during ISO 21496-1 reconstruction.
- Gain-map gamma is chosen by simulating 8-bit encode/decode error. Stored values
  use `pow(q, gamma)` and decoders use `pow(code, 1/gamma)`. The full-resolution
  map of an HDR input stores linear gain (gamma 1): its base already absorbs the
  code step, and nothing is interpolated.
- The Adaptive HDR base declares Display P3 twice, as nclx and as an ICC profile
  whose sRGB curve has its linear toe. An ICC-honouring reader decodes every base
  code, including the shadows under code 10 that a zero toe slope used to turn
  black in both the base and its reconstructed HDR.
- `2^headroom_stops` is the nominal global-curve target. Local highlight
  weighting can deliberately make the final rendered peak lower; the report
  records both values. Local weights are not normalized back to the largest
  gain: attenuation remains attenuation even in a mostly uniform image.
- RAW and SDR gain grids average individual pixel requests before local
  filtering. Below-knee pixels contribute zero, while mixed cells can retain
  a small highlight. Bilinear reconstruction can affect its immediate dark
  neighbours; `below_knee_relative_difference_max` measures that spill and
  the local-gain check also measures the far dark field. The 8-bit auxiliary gain image
  is HEVC-lossless, so zero gain cells survive Adaptive HEIC decoding exactly.
  Ultra HDR stores the map as
  a grayscale JPEG at quality 85 or higher, as recommended for JPEG/R; the
  requested quality still controls the SDR base.
- RAW is taken from LibRaw as linear camera RGB (`output_color` 0), after white
  balance, demosaic and highlight handling, and the camera matrix LibRaw
  selected is applied in float. LibRaw's own output spaces are converted in
  16-bit integers clamped to [0, 65535], which cuts off headroom above white
  (and XYZ, `output_color` 5, clips neutral highlights in its Z channel).
  A camera matrix extrapolates some saturated colours past the spectral locus:
  narrow-band blue light can land at zero or negative luminance and would
  render as black, and clamping the negative components, as LibRaw's output
  did at ProPhoto's boundary, leaves it nearly black with its hue shifted.
  Camera colours are instead compressed into AP1 (the ACES primaries, kept at
  D65) with the curve of the ACES Reference Gamut Compression, then converted
  to linear Display P3. Per component, the distance from the achromatic axis,
  `(max - c) / max`, is kept up to a threshold just above the farthest P3
  reaches in AP1 (0.945, 0.987 and 0.9955), so no colour inside P3 changes.
  Beyond it the curve (power 1.2) bends so that the farthest distance any
  non-negative camera RGB reaches through this image's matrix lands on the AP1
  boundary; those limits are computed exactly from the matrix, so no camera
  colour leaves AP1. The compression is scale-invariant and leaves headroom
  alone. Lower thresholds are smoother but move P3's most saturated colours
  (a common 0.95 shifts P3 red toward magenta by 6 CIEDE2000), because AP1's
  red-green edge runs along x + y = 1, as P3 red and the spectral locus from
  yellow to red do. Nothing is clamped to Rec.709/sRGB on the way, and
  out-of-P3 float components remain available until output-specific gamut
  handling. The report's `raw_color_matrix` says whose matrix was used; a
  camera LibRaw has no matrix for keeps its earlier treatment, camera RGB read
  as ProPhoto primaries, and is compressed the same way, but its decode is
  reported as degraded (`no_camera_matrix`) because none of its colours are
  calibrated.
  A DNG's colour calibration is applied as the DNG specification defines it and
  Adobe's DNG SDK computes it, where LibRaw applies the D65 ColorMatrix whatever
  the light. The white LibRaw balanced to (the reciprocal of the multipliers it
  applied) is located through the file's own matrices; the two calibrations,
  each ColorMatrix with its CameraCalibration and AnalogBalance, are
  interpolated in inverse colour temperature at that white, at the SDK's
  temperature for each illuminant (2850 K for standard light A, 6500 K for
  D65); and a ForwardMatrix, where present, takes over from the inverted
  ColorMatrix. CameraCalibration is used only when CameraCalibrationSignature
  and ProfileCalibrationSignature match (missing signatures default to empty);
  otherwise it is the identity matrix. The result is adapted from D50 to D65
  with Bradford. Neutrals do
  not move; how far other colours move depends on the camera, the content and
  how far the light is from D65 (on the decoded data of seven DNGs checked, a
  mean 0.4 to 3.0 ΔE ITP: a Ricoh GR IV 0.4 and 0.6 under 4600 to 4900 K and
  1.8 and 2.4 under 3300 to 3500 K, three HDR+ phone frames near 4700 to
  5100 K 0.9 to 3.0). A profile the SDK would refuse keeps LibRaw's matrix. A
  profile's HueSatMap, LookTable and tone curve are a look rather than
  calibration and are not applied.
  `render.wide_gamut_fraction` is measured on the decoded, linear-P3
  input before exposure or look processing: among pixels with P3 luminance at least
  `0.02`, it is the fraction outside Rec.709. The report also records its
  numerator, denominator, and threshold.
- RAW calibration is configurable before demosaic. Optional dcraw-format
  `--raw-bad-pixels` coordinates and `--raw-dark-frame` PGM samples refer to the
  original visible area, before DefaultCrop or orientation. The dark frame is
  a full-visible-area 16-bit P5 PGM containing the measured bias, including
  black; it replaces metadata black rather than being subtracted twice.
  Wrong dimensions, malformed headers and truncated pixels fail explicitly.
  On Fuji Super CCD, the visible area is the unpacked storage rectangle,
  not the larger diamond working raster. LUT, dark-frame and bad-pixel access
  use the storage bounds; shading and local highlight thresholds map each
  working CFA site back to that rectangle, including half-size decoding.
  CFA selection uses storage `COLOR` before rearrangement and working `FC`
  afterwards. Automatic bad-pixel neighbours preserve CFA phase on the
  densely packed Fuji axis. The Bayer mosaic API rejects diamond layouts.
  Phase One's metadata correction remains enabled on the normal LibRaw path.
  A measured dark frame is the fixed-pattern-noise path; no scene-derived
  row/column estimator is enabled.
- `--raw-linearization-lut` accepts `N` followed by `N` nondecreasing samples,
  in code values or normalized `[0,1]` values. The same interpolation transforms
  source codes, metadata black, white and any dark frame. Corrected samples are
  normalized by the transformed white-minus-black range and rebased to 16-bit
  codes before LibRaw; an affine LUT therefore leaves normalized signal intact.
  LUTs with no usable signal range are rejected.
- `--raw-lens-shading` accepts `width height channels` plus row-major gains,
  with 1, 3 (RGB), or 4 (R,G1,B,G2) channels. Its grid covers the original
  visible sensor area. Crop offsets and half-size CFA positions determine
  sampling locations. A gain shared by every channel throughout the effective
  crop is applied in float after LibRaw, including gains below one; unused map
  regions cannot change highlight recovery for such a crop. Bayer mosaic
  output applies all shading gains directly in float, preserving the original
  CFA's separate G1/G2 calibration and avoiding integer normalization loss.
  For rendered images with spatially varying or unequal channel gains, gains
  are still divided by their common maximum (at least 1) in the integer mosaic
  and that scale is restored in float. The bound uses all grid vertices that
  support the effective crop, including interpolation neighbours outside it;
  unrelated vertices cannot reduce crop precision. Fuji diamond layouts retain
  the full-grid bound because the working diamond spans the storage rectangle. Mosaic
  correction runs on independent rows in parallel. Blend uses the local calibrated
  clip reference after demosaic and before Fuji geometry, keeping the camera
  channel mean and shrinking chroma in floating-point arithmetic. For two
  green planes it uses the lower clip reference, a conservative policy that
  does not pretend to recover the separate signals after they were mixed.
  Reconstruct uses the same local channel references to select near-highlight
  colour-ratio seeds and clipped samples. It propagates calibrated camera
  ratios on a coarse grid, includes partial edge blocks, and only increases
  clipped channels. The reference channel stays unchanged. Where no colour
  evidence reaches a block, it retains dcraw mode 3's neutral ratio prior;
  this is a reconstruction assumption, not recovered sensor information.
  Extreme gain ratios still lose precision in the rendered integer mosaic;
  the floating-point Bayer output avoids that loss. After demosaic and median
  filtering, camera samples remain in float: reconstruction can exceed 65535
  without being clipped by LibRaw's output buffer. Fuji rotation, pixel-aspect
  interpolation and sensor orientation operate on these float samples before
  the camera colour transform. Aspect stretching retains the interpolation
  fraction discarded by LibRaw's integer implementation. The common exposure
  scale is restored once during the float colour transform.
  Explicit shading maps multiply the embedded DNG calibration, so they must
  describe residual correction when the DNG already contains a gain map.
- A DNG's opcode lists, which LibRaw reads but never applies, are applied where
  they describe the raw data. OpcodeList1's FixBadPixelsConstant is fixed as the
  DNG SDK fixes it (a green pixel from its diagonal neighbours, red or blue from
  the same colour two pixels away) and FixBadPixelsList from the nearest ring
  of good same-colour pixels, both on the stored sensor values. OpcodeList2's
  GainMap, the lens and colour shading correction Android phones write, runs
  on linear values after black and white normalisation (the path a
  linearization LUT takes, so LibRaw's maximum adjustment is off), interpolated
  over the active area as the SDK interpolates it and clipped at white, so the
  whole frame keeps one clip level for highlight recovery. On the HDR+ DNGs
  checked the correction brightens the corners 2 to 2.8 times, and the radial
  brightness of the renders follows the phone's own JPEG: in one frame, from
  half to 70% of the way to the corners, the median is 1.69 times the centre's
  against 1.95 in that JPEG, where it was 0.90.
  Any other opcode a file does not mark optional, such as OpcodeList3's
  lens-distortion warps, is not applied and the decode is reported as degraded
  (`dng_opcode_unsupported`); an opcode list that does not parse reports
  `dng_opcode_list_malformed`.
- The opt-in `--raw-auto-bad-pixels` detector replaces extreme outliers using
  same-CFA neighbours before code calibration. `--raw-gain` multiplies the
  decoded float scene-linear image; it cannot recover earlier clipping and
  automatic exposure may compensate its brightness change. RAW controls and
  calibration-file contents participate in decode caches and resume identity.
- RAW-domain consumers can call `decode_raw_mosaic()` and `pack_bayer()`. The
  former returns black-corrected, white-level-normalized Bayer samples in sensor
  coordinates; the latter produces `H/2 x W/2 x 4` in fixed `R,Gr,Gb,B` order.
  X-Trans and other non-2x2 CFAs are rejected instead of being silently labelled
  RGGB. The normal export path still demosaics through LibRaw because its
  downstream contract is linear Display P3 RGB.
- The SDR base is quantized with deterministic TPDF dithering, suppressing sky and
  gradient banding that the multiplicative gain map would otherwise amplify.
- The HEIF/BMFF item topology, `tmap` payload layout, and structural verifier are
  unchanged. Ultra HDR JPEG/R output uses Google's reference container writer.
  Every output is decoded and semantically verified before publication.

## Acceptance checklist

Validate each generated HEIC with `inspect` and `verify`, or each Ultra HDR JPEG
with `verify`, then test the file on a compatible HDR device. Use at least these scenes:

1. Daytime diffuse light: stable midtones, restrained white walls, natural skin
   and vegetation.
2. Strong highlights: lights, sunlight, and reflections roll smoothly into HDR
   without dead-white plates, fluorescent colour, or gain halos.
3. High-ISO night: target middle grey remains dark, exposure does not lift the
   whole scene into daytime, and black surroundings stay free of gain pumping.

The automated suite covers curve continuity/monotonicity, gamma round trips,
local gain behaviour, common-RGB reconstruction, ISO gain-map metadata round
trips, and HEIC/TMAP and Ultra HDR JPEG/R encode/decode. Visual device review
remains the final display-specific acceptance gate.
