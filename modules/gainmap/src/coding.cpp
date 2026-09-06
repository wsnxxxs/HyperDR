#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/types.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace hyperdr {

void measure_quantized_gain(RenderStats& stats, const FloatImage& codes,
                            float gain_max, float gamma, float ceiling) {
  std::array<std::uint64_t, 256> histogram{};
  for (float code : codes.pixels) {
    ++histogram[static_cast<std::size_t>(std::clamp(std::lround(code * 255.0F), 0L, 255L))];
  }
  std::array<float, 256> decoded{};
  std::uint64_t over_half = 0, over_one = 0, over_two = 0, clipped = 0;
  for (std::size_t code = 0; code < histogram.size(); ++code) {
    decoded[code] = gain_max * decode_gain_code(static_cast<float>(code) / 255.0F, gamma);
    if (decoded[code] > 0.5F) over_half += histogram[code];
    if (decoded[code] > 1.0F) over_one += histogram[code];
    if (decoded[code] > 2.0F) over_two += histogram[code];
    if (ceiling > kEpsilon && decoded[code] >= ceiling - kEpsilon) clipped += histogram[code];
  }
  const float count = static_cast<float>(codes.pixels.size());
  stats.gain_fraction_gt_0_5 = count ? static_cast<float>(over_half) / count : 0.0F;
  stats.gain_fraction_gt_1_0 = count ? static_cast<float>(over_one) / count : 0.0F;
  stats.gain_fraction_gt_2_0 = count ? static_cast<float>(over_two) / count : 0.0F;
  stats.gain_clipped_fraction = count ? static_cast<float>(clipped) / count : 0.0F;
  constexpr std::array<float, 8> fractions{0.50F, 0.75F, 0.90F, 0.95F,
                                        0.99F, 0.999F, 0.9999F, 1.0F};
  stats.gain_percentiles.fill(0.0F);
  if (codes.pixels.empty()) return;
  std::size_t code = 0;
  std::uint64_t cumulative = histogram[0];
  for (std::size_t i = 0; i < fractions.size(); ++i) {
    const auto rank = static_cast<std::uint64_t>(fractions[i] *
                         static_cast<float>(codes.pixels.size() - 1));
    while (cumulative <= rank && code < 255) cumulative += histogram[++code];
    stats.gain_percentiles[i] = decoded[code];
  }
}

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
  std::vector<float> samples(sample_count), weights(sample_count);
  for (std::size_t sample = 0; sample < sample_count; ++sample) {
    samples[sample] = clamp_finite(sample_at(sample), 0.0F, 1.0F);
    weights[sample] = 1.0F + 0.15F / (samples[sample] + 0.05F);
  }
  float best_gamma = 1.0F;
  double best_error = std::numeric_limits<double>::infinity();
  double unity_error = std::numeric_limits<double>::infinity();
  for (const float candidate : candidates) {
    // Quantization leaves only 256 possible decoded values. This exact table
    // removes a pow per sample without approximating the gamma search.
    std::array<float, 256> decoded_codes{};
    for (std::size_t code = 0; code < decoded_codes.size(); ++code)
      decoded_codes[code] = decode_gain_code(static_cast<float>(code) / 255.0F, candidate);
    double error = 0.0;
    for (std::size_t sample = 0; sample < sample_count; ++sample) {
      const float q = samples[sample];
      const auto encoded = static_cast<std::size_t>(std::round(255.0F * std::pow(q, candidate)));
      const float decoded = decoded_codes[encoded];
      const float weight = weights[sample];
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
