#pragma once

// Numeric helpers shared across every layer.
//
// These used to exist in three copies: `clamp_finite`/`luminance`/`percentile`
// in src/photographic_detail.hpp, the same three again inside gain_map.cpp, and
// `rational_from_float` in both gain_map.cpp and photographic_look.cpp. Three
// copies of a rounding rule is three chances for the SDR base and the gain map
// to disagree about the same pixel, so there is now exactly one of each.

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <vector>

namespace hyperdr {

// Guard band for log ratios and divisions throughout the renderer.
inline constexpr float kEpsilon = 1.0e-6F;

// Replaces a non-finite value with the low bound rather than propagating NaN
// into an encoded pixel, where it would become an arbitrary code value.
[[nodiscard]] inline float clamp_finite(float value, float low, float high) {
  if (!std::isfinite(value)) return low;
  return std::clamp(value, low, high);
}

[[nodiscard]] inline float positive_finite(float value) {
  return std::isfinite(value) && value > 0.0F ? value : 0.0F;
}

// Hermite smoothstep. Outside [low, high] it saturates; a degenerate interval
// becomes a step so callers never divide by zero.
[[nodiscard]] inline float smoothstep(float low, float high, float value) {
  if (!(high > low)) return value >= high ? 1.0F : 0.0F;
  const float t = std::clamp((value - low) / (high - low), 0.0F, 1.0F);
  return t * t * (3.0F - 2.0F * t);
}

// Nearest-rank percentile. Reorders `values`, which is what makes it O(n).
[[nodiscard]] inline float percentile(std::vector<float>& values, float fraction) {
  if (values.empty()) return 0.0F;
  const auto index = static_cast<std::size_t>(
      std::clamp(fraction, 0.0F, 1.0F) * static_cast<float>(values.size() - 1));
  std::nth_element(values.begin(),
                   values.begin() + static_cast<std::ptrdiff_t>(index),
                   values.end());
  return values[index];
}

}  // namespace hyperdr
