#pragma once

// Pure, dependency-free colour and quantization helpers shared by the codec
// front-ends (raw decode, HEIC encode) and the core unit tests. Keeping the
// maths here means the risky parts (wide-gamut conversion, dithered
// quantization) are testable in the dependency-free core build even though the
// LibRaw/libheif front-ends are not.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>

namespace hyperdr {

// Display P3 D65 luminance. The one definition of "how bright is this pixel"
// used by the tone curve, the headroom selector, the gain map, and the report;
// three copies of these coefficients used to be spread across the renderer.
[[nodiscard]] inline float p3_luminance(float r, float g, float b) {
  return std::max(0.0F, 0.2289746F * r + 0.6917385F * g + 0.0792869F * b);
}

// LibRaw XYZ output (output_color = 5), D65-adapted via the camera matrix and
// camera white balance, converted to linear Display P3 (D65). Matrix verified
// numerically: it is the inverse of the standard Display-P3(linear)->XYZ(D65)
// matrix, whose luminance row equals the P3 coefficients used elsewhere.
// Colours outside P3 produce a negative component and are clamped to the P3
// gamut boundary here rather than being pre-clipped to Rec.709 during decode.
[[nodiscard]] inline std::array<float, 3> xyz_d65_to_linear_p3(float X, float Y,
                                                               float Z) {
  return {std::max(0.0F, 2.4934969F * X - 0.9313836F * Y - 0.4027108F * Z),
          std::max(0.0F, -0.8294890F * X + 1.7626641F * Y + 0.0236247F * Z),
          std::max(0.0F, 0.0358458F * X - 0.0761724F * Y + 0.9568845F * Z)};
}

// LibRaw ProPhoto output (output_color = 4), D65-referred and linear, converted
// to linear Display P3. Unlike LibRaw's 16-bit XYZ output, ProPhoto's matrix
// rows sum to one, so a neutral D65 highlight reaches the container boundary
// without clipping only the Z channel. Keep this transform linear: negative
// out-of-P3 components and values above 1 carry real colour/headroom data and
// must not be clipped during RAW decode.
[[nodiscard]] inline std::array<float, 3> prophoto_to_linear_p3(float r, float g,
                                                                float b) {
  return {1.63242344F * r - 0.37959635F * g - 0.25282168F * b,
          -0.15369219F * r + 1.16669685F * g - 0.01300747F * b,
          0.01038550F * r - 0.06280994F * g + 1.05242565F * b};
}

// Alternative wide-gamut entry point when LibRaw is configured for Rec.2020
// output (output_color = 8, index is LibRaw-version dependent). Rec.2020 fully
// contains Display P3, so this is also gamut-safe. Matrix verified numerically.
[[nodiscard]] inline std::array<float, 3> rec2020_to_linear_p3(float r, float g,
                                                               float b) {
  return {std::max(0.0F, 1.3435783F * r - 0.2821797F * g - 0.0613986F * b),
          std::max(0.0F, -0.0652975F * r + 1.0757879F * g - 0.0104905F * b),
          std::max(0.0F, 0.0028218F * r - 0.0195985F * g + 1.0167767F * b)};
}

// Rec.709/sRGB primaries to Display P3, both linear and D65. This is the
// inverse of the P3->709 matrix used by is_outside_rec709 below, and is needed
// when an input already carries Rec.709 primaries (an Ultra HDR JPEG decoded
// through libultrahdr, for example) and has to enter the P3 working space.
[[nodiscard]] inline std::array<float, 3> rec709_to_linear_p3(float r, float g,
                                                              float b) {
  return {std::max(0.0F, 0.82246197F * r + 0.17753803F * g),
          std::max(0.0F, 0.03319420F * r + 0.96680580F * g),
          std::max(0.0F, 0.01708263F * r + 0.07239741F * g + 0.91051996F * b)};
}

// True when a linear Display P3 colour lies outside the Rec.709 (sRGB) gamut,
// i.e. reproducing its chromaticity in Rec.709 would need a negative primary.
// The test is relative to the brightest channel so it is exposure-invariant and
// near-black noise does not register as wide-gamut. Matrix is P3(lin)->709(lin),
// verified numerically.
[[nodiscard]] inline bool is_outside_rec709(float r, float g, float b,
                                            float relative_eps = 1.0e-3F) {
  const float R = 1.22494018F * r - 0.22494018F * g;
  const float G = -0.04205695F * r + 1.04205695F * g;
  const float B = -0.01963755F * r - 0.07863605F * g + 1.09827360F * b;
  const float lo = std::min({R, G, B});
  const float hi = std::max({std::max({R, G, B}), 1.0e-6F});
  return (lo / hi) < -relative_eps;
}

// Deterministic per-position hash -> uniform in [0, 1). Deterministic output is
// required so that encoding is reproducible (the test suite compares bytes).
[[nodiscard]] inline std::uint32_t color_hash_u32(std::uint32_t v) {
  v ^= v >> 16;
  v *= 0x7feb352dU;
  v ^= v >> 15;
  v *= 0x846ca68bU;
  v ^= v >> 16;
  return v;
}

[[nodiscard]] inline float dither_uniform01(std::uint32_t x, std::uint32_t y,
                                            std::uint32_t c, std::uint32_t salt) {
  const std::uint32_t h = color_hash_u32(x * 0x9e3779b1U ^ y * 0x85ebca77U ^
                                         c * 0xc2b2ae3dU ^ salt * 0x27d4eb2fU);
  return static_cast<float>(h >> 8) * (1.0F / 16777216.0F);  // 24-bit, [0, 1)
}

// Quantize a [0, 1] value to an integer code in [0, max_code] with triangular
// (TPDF, +/-1 LSB) dithering. TPDF has zero mean, so it preserves the average
// value while decorrelating quantization error and removing visible banding in
// smooth gradients such as skies.
[[nodiscard]] inline int quantize_dithered(float value01, unsigned max_code,
                                           std::uint32_t x, std::uint32_t y,
                                           std::uint32_t c) {
  const float scaled = std::clamp(value01, 0.0F, 1.0F) *
                       static_cast<float>(max_code);
  const float tpdf = dither_uniform01(x, y, c, 0U) +
                     dither_uniform01(x, y, c, 1U) - 1.0F;  // [-1, 1)
  const long code = std::lround(scaled + tpdf);
  return static_cast<int>(
      std::clamp<long>(code, 0L, static_cast<long>(max_code)));
}

}  // namespace hyperdr
