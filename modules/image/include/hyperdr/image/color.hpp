#pragma once

// Pure, dependency-free colour and quantization helpers shared by the codec
// front-ends (raw decode, HEIC encode) and the core unit tests. Keeping the
// maths here means the risky parts (wide-gamut conversion, dithered
// quantization) are testable in the dependency-free core build even though the
// system/third-party codec front-ends are not.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <string_view>

namespace hyperdr {

enum class ColorGamut : std::uint8_t {
  kSrgb,
  kDisplayP3,
  kRec2020,
};

[[nodiscard]] inline const char* color_gamut_name(ColorGamut gamut) {
  switch (gamut) {
    case ColorGamut::kSrgb: return "srgb";
    case ColorGamut::kDisplayP3: return "p3";
    case ColorGamut::kRec2020: return "rec2020";
  }
  return "srgb";
}

[[nodiscard]] inline std::optional<ColorGamut> color_gamut_from_name(
    std::string_view name) {
  if (name == "srgb") return ColorGamut::kSrgb;
  if (name == "p3") return ColorGamut::kDisplayP3;
  if (name == "rec2020") return ColorGamut::kRec2020;
  return std::nullopt;
}

// Display P3 D65 luminance. The one definition of "how bright is this pixel"
// used by the tone curve, the headroom selector, the gain map, and the report;
// three copies of these coefficients used to be spread across the renderer.
[[nodiscard]] inline float p3_luminance(float r, float g, float b) {
  return std::max(0.0F, 0.2289746F * r + 0.6917385F * g + 0.0792869F * b);
}

// Linear Rec.2020 (BT.2100 HDR files, Ultra HDR BT.2100 images, PQ and HLG
// LUT outputs) to linear Display P3, unclamped. A Rec.2020 colour outside P3
// keeps its negative P3 component: clamping each channel here shifted its hue
// before any gamut decision was made, whereas the renderer's gamut fit keeps
// the luminance and hue. Matrix verified numerically.
[[nodiscard]] inline std::array<float, 3> rec2020_to_linear_p3(float r, float g,
                                                               float b) {
  return {1.3435783F * r - 0.2821797F * g - 0.0613986F * b,
          -0.0652975F * r + 1.0757879F * g - 0.0104905F * b,
          0.0028218F * r - 0.0195985F * g + 1.0167767F * b};
}

// Rec.709/sRGB primaries to Display P3, both linear and D65. This is the
// inverse of the P3->709 matrix used by is_outside_rec709 below, and is needed
// when an input already carries Rec.709 primaries (an Ultra HDR JPEG decoded
// from a gain-map JPEG, for example) and has to enter the P3 working space.
[[nodiscard]] inline std::array<float, 3> rec709_to_linear_p3(float r, float g,
                                                              float b) {
  return {std::max(0.0F, 0.82246197F * r + 0.17753803F * g),
          std::max(0.0F, 0.03319420F * r + 0.96680580F * g),
          std::max(0.0F, 0.01708263F * r + 0.07239741F * g + 0.91051996F * b)};
}

// The inverse matrix without the defensive P3-channel floor. Gamut fitting
// calls this only with a colour already inside the Rec.709 cube; retaining the
// un-clamped form avoids hiding the result of the hue-preserving compression.
[[nodiscard]] inline std::array<float, 3> rec709_to_linear_p3_unclamped(
    float r, float g, float b) {
  return {0.82246197F * r + 0.17753803F * g,
          0.03319420F * r + 0.96680580F * g,
          0.01708263F * r + 0.07239741F * g + 0.91051996F * b};
}

[[nodiscard]] inline std::array<float, 3> linear_p3_to_rec709(
    float r, float g, float b) {
  return {1.22494018F * r - 0.22494018F * g,
          -0.04205695F * r + 1.04205695F * g,
          -0.01963755F * r - 0.07863605F * g + 1.09827360F * b};
}

// Oklab (Bjorn Ottosson, 2020) from linear Display P3: Oklab's M1 applied to
// P3's D65 XYZ, a signed cube root, then M2. Scaling a colour scales L, a and b
// together, so its hue angle does not depend on exposure or on an HDR gain.
[[nodiscard]] inline std::array<float, 3> linear_p3_to_oklab(float r, float g,
                                                             float b) {
  const double l = std::cbrt(0.4813272912 * r + 0.4620679117 * g + 0.0564956029 * b);
  const double m = std::cbrt(0.2288381013 * r + 0.6532343999 * g + 0.1179544132 * b);
  const double s = std::cbrt(0.0839860178 * r + 0.2242727893 * g + 0.6922208389 * b);
  return {static_cast<float>(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s),
          static_cast<float>(1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s),
          static_cast<float>(0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)};
}

[[nodiscard]] inline std::array<float, 3> oklab_to_linear_p3(float L, float a,
                                                             float b) {
  const double l = L + 0.3963377774 * a + 0.2158037573 * b;
  const double m = L - 0.1055613458 * a - 0.0638541728 * b;
  const double s = L - 0.0894841775 * a - 1.2914855480 * b;
  const double l3 = l * l * l;
  const double m3 = m * m * m;
  const double s3 = s * s * s;
  return {static_cast<float>(3.1281105290 * l3 - 2.2570750184 * m3 + 0.1293047884 * s3),
          static_cast<float>(-1.0911281609 * l3 + 2.4132667618 * m3 - 0.3221681709 * s3),
          static_cast<float>(-0.0260136497 * l3 - 0.5080276490 * m3 + 1.5333166822 * s3)};
}

// Fits a linear Display P3 colour into [0, limit] on every channel of the
// selected output gamut, keeping its luminance (clamped to
// [0, limit]) and giving up only saturation. A colour already inside is
// returned unchanged; at the limit only neutral is left.
//
// Which hue is kept depends on the hue. A straight line toward neutral keeps
// the xy dominant wavelength, and for reds, oranges, yellows and greens the eye
// sees that line turn: fitting narrow-band LED colours along it missed their
// hue by 7.7 degrees on average in CAM16, 13.0 in IPT and 15.5 in ICtCp. Along
// the colour's Oklab hue those fell to 1.7, 7.0 and 6.5, so these hues keep
// their Oklab hue. For blues and violets (Oklab hue -150 to -60 degrees,
// feathered over 20 on each side) the four models disagree by up to 20 degrees
// about which path keeps the hue, and the Oklab one turned a blue light in a
// real night frame teal, so those keep the straight line. The feathered blend
// of two in-gamut colours of equal luminance stays inside and continuous.
[[nodiscard]] inline std::array<float, 3> fit_linear_p3_to_gamut(
    float r, float g, float b, float limit, ColorGamut gamut) {
  const std::array<double, 3> source{std::isfinite(r) ? r : 0.0,
                                     std::isfinite(g) ? g : 0.0,
                                     std::isfinite(b) ? b : 0.0};
  const double upper = std::isfinite(limit) ? std::max(0.0, static_cast<double>(limit))
                                            : std::numeric_limits<double>::max();
  const auto target_space = [gamut](const std::array<double, 3>& c) {
    if (gamut == ColorGamut::kSrgb) {
      return std::array<double, 3>{1.22494018 * c[0] - 0.22494018 * c[1],
                                   -0.04205695 * c[0] + 1.04205695 * c[1],
                                   -0.01963755 * c[0] - 0.07863605 * c[1] +
                                       1.09827360 * c[2]};
    }
    if (gamut == ColorGamut::kRec2020) {
      return std::array<double, 3>{0.753833 * c[0] + 0.198597 * c[1] + 0.047570 * c[2],
                                   0.045744 * c[0] + 0.941777 * c[1] + 0.012479 * c[2],
                                   -0.001210 * c[0] + 0.017602 * c[1] + 0.983608 * c[2]};
    }
    return c;
  };
  const auto inside = [&](const std::array<double, 3>& c, double tolerance) {
    for (const double value : target_space(c)) {
      if (!(value >= -tolerance && value <= upper + tolerance)) return false;
    }
    return true;
  };
  // The existing forward and inverse Rec.2020 matrices differ by less than
  // one part per million. Accept that round-trip noise at the boundary so a
  // nominal pure primary is not needlessly compressed.
  const double round_trip_tolerance = gamut == ColorGamut::kRec2020
      ? 1.0e-6 * std::max({1.0, std::abs(source[0]), std::abs(source[1]),
                          std::abs(source[2])}) : 0.0;
  if (inside(source, round_trip_tolerance)) {
    return {static_cast<float>(source[0]), static_cast<float>(source[1]),
            static_cast<float>(source[2])};
  }
  // Clamped in the target space (removing the search's tolerance) and returned
  // as P3; a Rec.2020 colour may retain negative P3 components.
  const auto finish = [&](const std::array<double, 3>& c) {
    auto t = target_space(c);
    for (auto& value : t) value = std::clamp(value, 0.0, upper);
    if (gamut == ColorGamut::kSrgb) {
      t = {0.82246197 * t[0] + 0.17753803 * t[1], 0.03319420 * t[0] + 0.96680580 * t[1],
           0.01708263 * t[0] + 0.07239741 * t[1] + 0.91051996 * t[2]};
    } else if (gamut == ColorGamut::kRec2020) {
      t = {1.3435783 * t[0] - 0.2821797 * t[1] - 0.0613986 * t[2],
           -0.0652975 * t[0] + 1.0757879 * t[1] - 0.0104905 * t[2],
           0.0028218 * t[0] - 0.0195985 * t[1] + 1.0167767 * t[2]};
    }
    return std::array<float, 3>{static_cast<float>(t[0]), static_cast<float>(t[1]),
                                static_cast<float>(t[2])};
  };
  constexpr std::array<double, 3> kLuminance{0.2289746, 0.6917385, 0.0792869};
  const auto luminance_of = [&](const std::array<double, 3>& c) {
    return kLuminance[0] * c[0] + kLuminance[1] * c[1] + kLuminance[2] * c[2];
  };
  const double luminance = std::clamp(luminance_of(source), 0.0, upper);
  const std::array<double, 3> neutral{luminance, luminance, luminance};
  if (!(luminance > 0.0) || !(luminance < upper)) return finish(neutral);

  const double l = std::cbrt(0.4813272912 * source[0] + 0.4620679117 * source[1] +
                             0.0564956029 * source[2]);
  const double m = std::cbrt(0.2288381013 * source[0] + 0.6532343999 * source[1] +
                             0.1179544132 * source[2]);
  const double s = std::cbrt(0.0839860178 * source[0] + 0.2242727893 * source[1] +
                             0.6922208389 * source[2]);
  const double L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s;
  const double A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s;
  const double B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
  if (!(std::hypot(A, B) > 1.0e-9)) return finish(neutral);
  const auto smoothstep = [](double edge0, double edge1, double x) {
    const double t = std::clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  };
  const double hue = std::atan2(B, A) * 180.0 / 3.14159265358979323846;
  const double straight_weight =
      smoothstep(-170.0, -150.0, hue) * (1.0 - smoothstep(-60.0, -40.0, hue));

  // The straight line toward neutral, cut where the first channel of the target
  // space reaches a bound. The target space maps neutral to neutral, so the
  // fraction found there is the same fraction of the line in P3.
  std::array<double, 3> straight = neutral;
  if (straight_weight > 0.0) {
    const auto t = target_space(source);
    double amount = 1.0;
    for (const double channel : t) {
      const double delta = channel - luminance;
      if (delta > 0.0) amount = std::min(amount, (upper - luminance) / delta);
      if (delta < 0.0) amount = std::min(amount, -luminance / delta);
    }
    amount = std::clamp(amount, 0.0, 1.0);
    for (std::size_t c = 0; c < 3; ++c) {
      straight[c] = luminance + amount * (source[c] - luminance);
    }
    if (!(straight_weight < 1.0)) return finish(straight);
  }

  // Saturation s keeps L and scales (a, b), which keeps the hue; the result is
  // then scaled back to the luminance, which keeps the hue again.
  const auto at = [&](double saturation, std::array<double, 3>& out) {
    const double ls = L + saturation * (0.3963377774 * A + 0.2158037573 * B);
    const double ms = L - saturation * (0.1055613458 * A + 0.0638541728 * B);
    const double ss = L - saturation * (0.0894841775 * A + 1.2914855480 * B);
    const double l3 = ls * ls * ls;
    const double m3 = ms * ms * ms;
    const double s3 = ss * ss * ss;
    const std::array<double, 3> rgb{
        3.1281105290 * l3 - 2.2570750184 * m3 + 0.1293047884 * s3,
        -1.0911281609 * l3 + 2.4132667618 * m3 - 0.3221681709 * s3,
        -0.0260136497 * l3 - 0.5080276490 * m3 + 1.5333166822 * s3};
    const double y = luminance_of(rgb);
    if (!(y > 0.0)) return false;
    const double scale = luminance / y;
    out = {rgb[0] * scale, rgb[1] * scale, rgb[2] * scale};
    return true;
  };
  // The largest saturation that fits, by bisection. Neutral is the fallback
  // when even a trace of the hue at this luminance falls outside.
  const double tolerance = 1.0e-7 * std::max(upper, 1.0);
  double low = 0.0;
  double high = 1.0;
  std::array<double, 3> best = neutral;
  for (int iteration = 0; iteration < 32; ++iteration) {
    const double middle = 0.5 * (low + high);
    std::array<double, 3> candidate{};
    if (at(middle, candidate) && inside(candidate, tolerance)) {
      low = middle;
      best = candidate;
    } else {
      high = middle;
    }
  }
  if (straight_weight > 0.0) {
    for (std::size_t c = 0; c < 3; ++c) {
      best[c] = straight_weight * straight[c] + (1.0 - straight_weight) * best[c];
    }
  }
  return finish(best);
}

[[nodiscard]] inline std::array<float, 3> fit_linear_p3_gamut(
    float r, float g, float b, float limit, bool rec709 = false) {
  return fit_linear_p3_to_gamut(r, g, b, limit,
      rec709 ? ColorGamut::kSrgb : ColorGamut::kDisplayP3);
}

// Fits a linear Display-P3 colour into the Rec.709 (sRGB) cube with
// fit_linear_p3_gamut: its luminance and hue are kept rather than being shifted
// by three independent channel clamps. HDR callers may preserve a common scale
// above one; SDR/base callers leave it false and target the ordinary [0, 1]
// cube.
[[nodiscard]] inline std::array<float, 3> compress_linear_p3_to_srgb(
    float r, float g, float b, bool preserve_headroom = false) {
  const float red = std::isfinite(r) ? r : 0.0F;
  const float green = std::isfinite(g) ? g : 0.0F;
  const float blue = std::isfinite(b) ? b : 0.0F;
  const auto source = linear_p3_to_rec709(red, green, blue);
  const float limit = preserve_headroom
                          ? std::max(1.0F, std::max({source[0], source[1], source[2]}))
                          : 1.0F;
  const auto fitted = fit_linear_p3_gamut(red, green, blue, limit, true);
  return {std::max(0.0F, fitted[0]), std::max(0.0F, fitted[1]),
          std::max(0.0F, fitted[2])};
}

// True when a linear Display P3 colour lies outside the Rec.709 (sRGB) gamut,
// i.e. reproducing its chromaticity in Rec.709 would need a negative primary.
// The test is relative to the brightest channel so it is exposure-invariant and
// near-black noise does not register as wide-gamut. Matrix is P3(lin)->709(lin),
// verified numerically.
[[nodiscard]] inline bool is_outside_rec709(float r, float g, float b,
                                            float relative_eps = 1.0e-3F) {
  const auto rec709 = linear_p3_to_rec709(r, g, b);
  const float R = rec709[0];
  const float G = rec709[1];
  const float B = rec709[2];
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
