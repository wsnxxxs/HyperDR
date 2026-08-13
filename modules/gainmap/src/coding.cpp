#include "hyperdr/gainmap/coding.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace hyperdr {

float encode_gain_code(float normalized_gain, float gamma) {
  if (!(std::isfinite(gamma) && gamma > 0.0F)) {
    throw std::invalid_argument("gain gamma must be positive and finite");
  }
  return std::pow(std::clamp(clamp_finite(normalized_gain, 0.0F, 1.0F), 0.0F, 1.0F), gamma);
}

float decode_gain_code(float encoded_gain, float gamma) {
  if (!(std::isfinite(gamma) && gamma > 0.0F)) {
    throw std::invalid_argument("gain gamma must be positive and finite");
  }
  return std::pow(std::clamp(clamp_finite(encoded_gain, 0.0F, 1.0F), 0.0F, 1.0F),
                  1.0F / gamma);
}

float quantize_gain_code_dithered(float encoded_gain, std::uint32_t x,
                                  std::uint32_t y) {
  const float code = clamp_finite(encoded_gain, 0.0F, 1.0F);
  if (code <= 0.0F) return 0.0F;
  if (code >= 1.0F) return 1.0F;
  // Preserve the zero-gain invariant around the knee. Because the grid is
  // bilinearly upsampled, also keep the first represented code stable: moving
  // 1 -> 2 LSBs can leak a visible gain into a below-knee sample. TPDF remains
  // active for the rest of the code range, where it breaks up smooth bands.
  const long baseline = std::lround(code * 255.0F);
  if (baseline <= 1L) {
    return static_cast<float>(std::clamp<long>(baseline, 0L, 255L)) /
           255.0F;
  }
  return static_cast<float>(quantize_dithered(code, 255U, x, y, 0U)) /
         255.0F;
}

float choose_gain_gamma(const std::vector<float>& normalized_gains) {
  if (normalized_gains.empty()) return 1.0F;
  // Gamma selection is a distribution estimate, not a per-pixel transform.
  // A deterministic stratified sample bounds the expensive pow() work while
  // preserving coverage of the entire grid (including spatially small tails).
  constexpr std::size_t kMaximumSamples = 65536;
  const std::size_t sample_count = std::min(normalized_gains.size(), kMaximumSamples);
  const auto sample_at = [&](const std::size_t sample) {
    if (sample_count == normalized_gains.size()) return normalized_gains[sample];
    const auto numerator = (static_cast<std::uint64_t>(sample) * 2U + 1U) *
                           normalized_gains.size();
    const auto index = static_cast<std::size_t>(
        numerator / (static_cast<std::uint64_t>(sample_count) * 2U));
    return normalized_gains[std::min(index, normalized_gains.size() - 1)];
  };
  constexpr std::array<float, 9> candidates{0.40F, 0.50F, 0.60F, 0.75F, 0.90F,
                                             1.00F, 1.20F, 1.50F, 2.00F};
  float best_gamma = 1.0F;
  double best_error = std::numeric_limits<double>::infinity();
  double unity_error = std::numeric_limits<double>::infinity();
  for (const float candidate : candidates) {
    double error = 0.0;
    for (std::size_t sample = 0; sample < sample_count; ++sample) {
      const float raw = sample_at(sample);
      const float q = std::clamp(clamp_finite(raw, 0.0F, 1.0F), 0.0F, 1.0F);
      const float encoded = std::round(255.0F * encode_gain_code(q, candidate)) / 255.0F;
      const float decoded = decode_gain_code(encoded, candidate);
      const float weight = 1.0F + 0.15F / (q + 0.05F);
      const float delta = decoded - q;
      error += static_cast<double>(weight) * delta * delta;
    }
    if (candidate == 1.0F) unity_error = error;
    if (error < best_error) {
      best_error = error;
      best_gamma = candidate;
    }
  }
  // Keep metadata simple when the quantization difference is not material.
  if (unity_error <= best_error * 1.01 + 1.0e-12) return 1.0F;
  return best_gamma;
}

}  // namespace hyperdr
