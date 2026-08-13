# Rendering and compatibility guarantees

What the renderer promises about its output, and the manual gate a release still
has to pass. For the options that drive it see
[cli-reference.md](cli-reference.md); for what a run records see
[report-schema.md](report-schema.md).

## Guarantees

- The photographic path uses a shared toe and middle segment for SDR and HDR.
  Their exponential shoulders asymptote to `1` and `2^headroom_stops` rather
  than hard-clipping highlights.
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
