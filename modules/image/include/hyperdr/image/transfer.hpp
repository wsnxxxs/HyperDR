#pragma once

// Every transfer function the pipeline encodes through: sRGB/Display-P3 for the
// SDR base and the gain map, PQ and HLG for the BT.2100 renditions, plus the
// P3 -> Rec.2020 primaries matrix those two share.
//
// PQ and HLG were private to the HEIF encoder until AVIF needed exactly the same
// maths. Sharing them keeps a PQ AVIF and a PQ HEIC bit-identical in their
// sample values, which is the only way the two containers can be described as
// the same rendition. sRGB arrived here from the gain-map renderer for the same
// reason: the base image and the file's own verification pass have to agree.

#include <algorithm>
#include <array>
#include <cmath>

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

[[nodiscard]] inline float hlg_oetf(float relative_linear) {
  constexpr float kNominalPeakNits = 1000.0F;
  constexpr float kSystemGamma = 1.2F;
  constexpr float a = 0.17883277F;
  constexpr float b = 0.28466892F;
  constexpr float c = 0.55991073F;
  // Undo the 1000-nit HLG display OOTF, then apply the BT.2100 scene OETF.
  // This places diffuse white (203 nits) at signal level 0.75.
  const float display =
      std::clamp(relative_linear * kReferenceWhiteNits / kNominalPeakNits, 0.0F, 1.0F);
  const float scene = std::pow(display, 1.0F / kSystemGamma);
  return scene <= 1.0F / 12.0F ? std::sqrt(3.0F * scene)
                               : a * std::log(12.0F * scene - b) + c;
}

}  // namespace hyperdr
