#pragma once

// Every transfer function the pipeline encodes and decodes through:
// sRGB/Display-P3 for the SDR base and the gain map, PQ and HLG for the BT.2100
// renditions, plus the P3 -> Rec.2020 primaries matrix those two share.
//
// PQ and HLG were private to the HEIF encoder until AVIF needed exactly the same
// maths. Sharing them keeps a PQ AVIF and a PQ HEIC bit-identical in their
// sample values, which is the only way the two containers can be described as
// the same rendition. sRGB arrived here from the gain-map renderer for the same
// reason: the base image and the file's own verification pass have to agree.
//
// The BT.2100 *inverses* live here too, beside the functions they undo. They
// used to be written out a second time inside the raster decoder, which meant
// reading back a PQ or HLG file this project had just written relied on two
// independent transcriptions of the same standard agreeing. They are each
// other's inverse by construction now, and transfer_test holds them to it.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>

namespace hyperdr {

// sRGB/Display-P3 encoding. Table-backed inside the [0, 1] range where almost
// every sample lands, and exact outside it, so an out-of-range highlight during
// reconstruction is still transformed correctly rather than clamped early.
[[nodiscard]] float srgb_oetf(float linear);
[[nodiscard]] float srgb_eotf(float encoded);

// BT.709 (and the identical BT.601 and BT.2020 SDR curves). This is *not*
// sRGB: the two differ by enough to matter, most visibly in the shadows, where
// decoding a 0.1 code as sRGB yields 0.0100 against BT.709's 0.0224 -- 55% too
// dark. A CICP transfer of 1, 6, 14 or 15 means this curve, and the decoder
// used to route all four through srgb_eotf.
//
// Only bt709_inverse_oetf is on a decode path; this forward curve exists so
// transfer_test can assert the pair round-trips, which is the property the
// decoder actually depends on.
[[nodiscard]] inline float bt709_oetf(float linear) {
  constexpr float kAlpha = 1.099F;
  constexpr float kBeta = 0.018F;
  const float clamped = std::max(0.0F, linear);
  return clamped < kBeta ? 4.5F * clamped
                         : kAlpha * std::pow(clamped, 0.45F) - (kAlpha - 1.0F);
}

[[nodiscard]] inline float bt709_inverse_oetf(float encoded) {
  constexpr float kAlpha = 1.099F;
  constexpr float kBeta = 0.018F;
  const float clamped = std::max(0.0F, encoded);
  return clamped < 4.5F * kBeta
             ? clamped / 4.5F
             : std::pow((clamped + (kAlpha - 1.0F)) / kAlpha, 1.0F / 0.45F);
}

// Diffuse white for both transfer functions. BT.2408 places graphics white at
// 203 nits, and every mapping here is anchored to it.
inline constexpr float kReferenceWhiteNits = 203.0F;

[[nodiscard]] inline std::array<float, 3> p3_to_rec2020(float r, float g, float b) {
  return {
      0.753833F * r + 0.198597F * g + 0.047570F * b,
      0.045744F * r + 0.941777F * g + 0.012479F * b,
      -0.001210F * r + 0.017602F * g + 0.983608F * b,
  };
}

[[nodiscard]] inline float pq_oetf(float relative_linear) {
  constexpr float m1 = 2610.0F / 16384.0F;
  constexpr float m2 = 2523.0F / 32.0F;
  constexpr float c1 = 3424.0F / 4096.0F;
  constexpr float c2 = 2413.0F / 128.0F;
  constexpr float c3 = 2392.0F / 128.0F;
  const float normalized =
      std::clamp(relative_linear * kReferenceWhiteNits / 10000.0F, 0.0F, 1.0F);
  const float p = std::pow(normalized, m1);
  return std::pow((c1 + c2 * p) / (1.0F + c3 * p), m2);
}

[[nodiscard]] inline float pq_eotf(float encoded) {
  constexpr float m1 = 2610.0F / 16384.0F;
  constexpr float m2 = 2523.0F / 32.0F;
  constexpr float c1 = 3424.0F / 4096.0F;
  constexpr float c2 = 2413.0F / 128.0F;
  constexpr float c3 = 2392.0F / 128.0F;
  const float p = std::pow(std::max(0.0F, encoded), 1.0F / m2);
  const float normalized_10000_nits =
      std::pow(std::max(p - c1, 0.0F) / std::max(c2 - c3 * p, 1.0e-6F), 1.0F / m1);
  return normalized_10000_nits * 10000.0F / kReferenceWhiteNits;
}

// The BT.2100 HLG reference display: a 1000 cd/m² nominal peak and the system
// gamma of 1.2 that goes with it. Its OOTF is defined on Rec.2020 luminance.
inline constexpr float kHlgNominalPeakNits = 1000.0F;
inline constexpr float kHlgSystemGamma = 1.2F;
inline constexpr std::array<float, 3> kRec2020Luminance{0.2627F, 0.6780F, 0.0593F};

// The BT.2100 HLG OETF on normalized scene light in [0, 1], and its inverse.
// No OOTF: these are per channel by definition.
[[nodiscard]] inline float hlg_oetf_scene(float scene) {
  constexpr float a = 0.17883277F;
  constexpr float b = 0.28466892F;
  constexpr float c = 0.55991073F;
  const float e = std::max(0.0F, scene);
  return e <= 1.0F / 12.0F ? std::sqrt(3.0F * e) : a * std::log(12.0F * e - b) + c;
}

[[nodiscard]] inline float hlg_inverse_oetf_scene(float signal) {
  constexpr float a = 0.17883277F;
  constexpr float b = 0.28466892F;
  constexpr float c = 0.55991073F;
  const float s = std::max(0.0F, signal);
  return s <= 0.5F ? (s * s) / 3.0F : (std::exp((s - c) / a) + b) / 12.0F;
}

// Display light relative to diffuse white to an HLG signal: BT.2100's inverse
// OOTF, then the OETF on each channel. Diffuse white (203 cd/m²) lands at 0.75.
// The OOTF works on luminance -- the colour is scaled by a power of its own
// luminance -- so channel ratios survive it. Raising each channel to the system
// gamma instead, as this project used to, over-saturated every HLG colour
// relative to a BT.2100 display. `weights` are the luminance weights of the
// signal's primaries (Rec.2020 unless an HLG signal says otherwise).
[[nodiscard]] inline std::array<float, 3> hlg_encode(
    const std::array<float, 3>& relative,
    const std::array<float, 3>& weights = kRec2020Luminance) {
  const double scale = kReferenceWhiteNits / kHlgNominalPeakNits;
  std::array<double, 3> display{};
  for (std::size_t c = 0; c < 3; ++c) {
    display[c] = std::isfinite(relative[c]) ? std::max(0.0, relative[c] * scale) : 0.0;
  }
  const double luminance =
      weights[0] * display[0] + weights[1] * display[1] + weights[2] * display[2];
  if (!(luminance > 0.0)) return {0.0F, 0.0F, 0.0F};
  // HLG's display volume is not a fixed RGB cube: at luminance Y the
  // inverse OOTF requires each display channel <= Y^((gamma-1)/gamma).
  // Fit toward neutral at the same luminance before encoding, so a saturated
  // highlight gives up only unrepresentable chroma rather than also losing
  // brightness when its scene-light channel is clipped to one.
  if (luminance >= 1.0) return {1.0F, 1.0F, 1.0F};
  const double maximum = std::pow(luminance, 1.0 - 1.0 / kHlgSystemGamma);
  const double peak = std::max({display[0], display[1], display[2]});
  if (peak > maximum) {
    const double amount = (maximum - luminance) / (peak - luminance);
    for (double& channel : display) {
      channel = luminance + amount * (channel - luminance);
    }
  }
  const double factor = std::pow(luminance, 1.0 / kHlgSystemGamma - 1.0);
  std::array<float, 3> signal{};
  for (std::size_t c = 0; c < 3; ++c) {
    signal[c] = hlg_oetf_scene(static_cast<float>(std::min(1.0, display[c] * factor)));
  }
  return signal;
}

// The inverse of hlg_encode: the OETF undone on each channel, then the OOTF on
// the scene luminance, returned relative to diffuse white.
[[nodiscard]] inline std::array<float, 3> hlg_decode(
    const std::array<float, 3>& signal,
    const std::array<float, 3>& weights = kRec2020Luminance) {
  std::array<double, 3> scene{};
  for (std::size_t c = 0; c < 3; ++c) scene[c] = hlg_inverse_oetf_scene(signal[c]);
  const double luminance =
      weights[0] * scene[0] + weights[1] * scene[1] + weights[2] * scene[2];
  if (!(luminance > 0.0)) return {0.0F, 0.0F, 0.0F};
  const double factor = std::pow(luminance, kHlgSystemGamma - 1.0) * kHlgNominalPeakNits /
                        kReferenceWhiteNits;
  return {static_cast<float>(scene[0] * factor), static_cast<float>(scene[1] * factor),
          static_cast<float>(scene[2] * factor)};
}

}  // namespace hyperdr
