# Rendering and compatibility guarantees

What the renderer promises about its output, and the manual gate a release still
has to pass. For the options that drive it see
[cli-reference.md](cli-reference.md); for what a run records see
[report-schema.md](report-schema.md).

## Input domains

Three kinds of input reach the renderer, and they are not interchangeable. The
decoder records which one it produced, in `DecodedImage::domain`; the report
carries it as `input_domain`. Nothing branches on the file extension.

| Domain | Produced by | What 1.0 means | Renderer |
| --- | --- | --- | --- |
| `scene-referred` | RAW through LibRaw | wherever white balance landed | photographic curve, automatic exposure |
| `display-referred-sdr` | JPEG, PNG, SDR HEIC/AVIF, an Ultra HDR JPEG that fell back to its primary | diffuse white, and the ceiling | identity, zero gain map |
| `display-referred-hdr` | PQ/HLG HEIC and AVIF, Ultra HDR, a gain-map HEIC | diffuse white, with real detail above it | log-domain shoulder, split at the declared headroom |

- **A scene-referred input** is developed: the photographic curve below chooses
  an exposure from the scene's log average and selects headroom from content.
- **A display-referred SDR input** is already a finished photograph, so it is
  passed through unchanged and its gain map is zero. HyperDR does not
  manufacture highlight range from an input that never carried any. Exposure
  controls still apply — a manual `--exposure` and `--exposure-bias` both scale
  the image — and when that scaling would push the picture past 1.0 the excess
  is rolled off by the shoulder rather than clipped. Automatic exposure is not
  consulted: its input is the scene's log average, which on a graded picture
  measures the grade.
- **A display-referred HDR input** is split rather than re-developed. Both
  renditions come from one shoulder in the log domain: identity below the knee
  (`--expansion-start`), slope exactly 1 at the knee, and asymptotic above it.
  The ceiling is the only difference between the two. Each ceiling is *solved*
  so the input's declared peak lands exactly on its target — 1.0 for the base,
  the output headroom for the rendition — because a shoulder only approaches
  its ceiling, and assuming it instead rendered a 1.06-stop input at 0.42 stops.
  When the output budget covers everything the input declared, the rendition is
  the input, unmodified.
- The output headroom is the input's declared headroom capped by
  `--headroom`/`--headroom-max` and scaled by `--gain-strength`, so an
  over-range input is attenuated deliberately instead of being flattened
  against the format ceiling. Because ISO 21496-1 metadata declares the gain
  interval as the alternate headroom, this is also what makes re-export stable:
  a gain-map HEIC round-trips at 2.08x across passes, drifting only by 8-bit
  gain quantization, where it previously lost roughly a third of its range each
  time.
- The gain a cell carries is the mean of the gain its own pixels ask for, with
  below-knee pixels contributing zero — the gain map downsampled, rather than
  the gain of the downsampled image, so a small specular is not averaged away
  before it is ever restored. Because the grid is then sampled bilinearly, a
  shadow pixel bordering a bright cell still receives a little gain; the report
  measures exactly how much as `render.below_knee_relative_difference_max`.

Working in the log domain is what makes a large input headroom usable. A
linear-domain shoulder asymptotic to 1.0 spends nearly its whole output range
on the first two stops: a PQ input reaching 49x diffuse white arrived at the
8-bit base with everything above roughly 1.5x sharing the top two code values.
The log-domain shoulder spreads the same 5.6 stops across roughly 26 codes at
the default knee, and leaves everything below the knee bit-exact.

The headroom the split uses is the one the *container declared*, never a
percentile of the pixels. An HDR file whose colour is described by an ICC
profile rather than by CICP therefore reports SDR and is passed through: an ICC
profile cannot state a headroom, and rendering such a file faithfully is better
than inventing a range for it.

## Guarantees

- The photographic path uses a shared toe and middle segment for SDR and HDR.
  Their exponential shoulders asymptote to `1` and `2^headroom_stops` rather
  than hard-clipping highlights. It runs for scene-referred input only; see
  **Input domains** above for what the other two get.
- A single-channel gain map can only reconstruct a common RGB multiplier. Shared
  vibrance, highlight-to-white convergence, and hue-preserving gamut compression
  therefore happen before the SDR/HDR luminance split.
- Gain maps write zero base and alternate offsets, preserving common RGB ratios
  during ISO 21496-1 reconstruction.
- Gain-map gamma is chosen by simulating 8-bit encode/decode error. Stored values
  use `pow(q, gamma)` and decoders use `pow(code, 1/gamma)`.
- `2^headroom_stops` is the nominal global-curve target. Local highlight
  weighting can deliberately make the final rendered peak lower; the report
  records both values.
- Any gain-grid node that would bilinearly influence an SDR-only pixel is set to
  zero before encoding. The 8-bit auxiliary gain image is HEVC-lossless, so zero
  gain cells survive Adaptive HEIC decoding exactly. Ultra HDR stores the map as
  a grayscale JPEG at quality 85 or higher, as recommended for JPEG/R; the
  requested quality still controls the SDR base.
- RAW is decoded through LibRaw's linear ProPhoto output (`output_color` 4), then
  transformed in float to linear Display P3. ProPhoto is intentional: XYZ
  (`output_color` 5) can clip neutral highlights in its Z channel before the
  float conversion because that matrix row sums above one. Neither path passes
  through Rec.709/sRGB, and out-of-P3 float components remain available until
  output-specific gamut handling. `render.wide_gamut_fraction` is measured on the decoded, linear-P3
  input before exposure or look processing: among pixels with P3 luminance at least
  `0.02`, it is the fraction outside Rec.709. The report also records its
  numerator, denominator, and threshold.
- RAW calibration is configurable before demosaic. LibRaw applies the metadata
  black level, camera white balance, optional bad-pixel coordinate map
  (`--raw-bad-pixels`), and dark-frame PGM (`--raw-dark-frame`); Phase One's
  metadata linearization/defect correction is enabled explicitly. An external
  dark frame is also the supported fixed-pattern-noise path: row/column bias is
  removed when it is present in that measured frame; no scene-derived
  row/column estimator is enabled by default because it could confuse real
  image gradients with sensor noise.
  A code LUT can be supplied with `--raw-linearization-lut`: its text format is
  `N` followed by `N` samples, either raw code values or normalized `[0,1]`
  values. A lens-shading map can be supplied with `--raw-lens-shading`; its
  format is `width height channels` followed by row-major gains, with 1, 3
  (RGB), or 4 (R,G1,B,G2) channels. The opt-in `--raw-auto-bad-pixels` detector
  only replaces extreme zero/saturated outliers with same-CFA neighbours, so a
  supplied calibration map remains preferred for scientific work. `--raw-gain`
  is a sensor-domain digital gain and is included in the decode cache and resume
  fingerprint.
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
