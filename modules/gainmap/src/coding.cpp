#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/gainmap/types.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <limits>
#include <numeric>
#include <stdexcept>

namespace hyperdr {

void align_zero_gain(Rational& minimum, Rational& maximum, unsigned bit_depth) {
  if (bit_depth != 8 && bit_depth != 10)
    throw std::invalid_argument("gain bit depth must be 8 or 10");
  const auto value = [](Rational r) { return double(r.numerator) / r.denominator; };
  const double low = value(minimum), high = value(maximum);
  if (!(low < 0 && high > 0)) return; // Zero is already an endpoint.
  const std::int64_t levels = (1U << bit_depth) - 1;
  const auto requested = static_cast<std::int64_t>(std::ceil(-low * levels / (high - low)));
  const auto zero = std::clamp<std::int64_t>(requested, 1, levels - 1);
  const auto fraction = [](std::int64_t n, std::int64_t d, Rational& out) {
    const auto divisor = std::gcd(n, d); n /= divisor; d /= divisor;
    if (n < std::numeric_limits<std::int32_t>::min() || n > std::numeric_limits<std::int32_t>::max() ||
        d > std::numeric_limits<std::uint32_t>::max()) return false;
    out = {static_cast<std::int32_t>(n), static_cast<std::uint32_t>(d)}; return true;
  };
  // A common rational step makes the integer zero code mathematically exact.
  // Usually retain max and expand min. If zero would be the last code while
  // max is positive, retain min and leave one positive code instead.
  if (requested < levels) {
    if (fraction(-std::int64_t(maximum.numerator) * zero,
                 std::int64_t(maximum.denominator) * (levels-zero), minimum)) return;
  } else {
    if (fraction(-std::int64_t(minimum.numerator) * (levels-zero),
                 std::int64_t(minimum.denominator) * zero, maximum)) return;
  }
  // Large coprime rationals may exceed ISO's integer fields after expansion.
  // A binary rational step rounded up covers both endpoints without overflow.
  constexpr std::int64_t denominator = 65536;
  const auto step = static_cast<std::int64_t>(std::ceil(
      std::max(-low/zero, high/(levels-zero)) * denominator));
  if (!fraction(-step*zero, denominator, minimum) ||
      !fraction(step*(levels-zero), denominator, maximum))
    throw std::invalid_argument("zero-aligned gain range is not representable");
}

void measure_quantized_gain(RenderStats& stats, const FloatImage& codes,
                            float gain_max, float gamma, float ceiling, float gain_min) {
  std::array<std::uint64_t, 256> histogram{};
  const auto stride = static_cast<std::size_t>(codes.width) * codes.channels;
  for (std::uint32_t y = 0; y < codes.height; ++y) {
    check_cancelled();
    for (std::size_t i = y * stride; i < (y + 1) * stride; ++i) {
      const auto code = codes.pixels[i];
      ++histogram[static_cast<std::size_t>(std::clamp(std::lround(code * 255.0F), 0L, 255L))];
    }
  }
  std::array<float, 256> decoded{};
  std::uint64_t over_half = 0, over_one = 0, over_two = 0, clipped = 0;
  for (std::size_t code = 0; code < histogram.size(); ++code) {
    decoded[code] = std::lerp(gain_min, gain_max,
        decode_gain_code(static_cast<float>(code) / 255.0F, gamma));
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

float choose_gain_gamma(std::span<const float> normalized_gains) {
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

QuantizedGainGrid quantize_gain_grid(std::span<const float> gain_stops,
                                     std::uint32_t width) {
  if (width == 0 || gain_stops.size() % width != 0) {
    throw std::invalid_argument("gain grid dimensions do not match its samples");
  }
  QuantizedGainGrid quantized;
  float gain_max = 0.0F;
  for (const float value : gain_stops) gain_max = std::max(gain_max, value);
  quantized.gain_max_metadata = rational_from_float(gain_max);
  quantized.stored_gain_max = rational_value(quantized.gain_max_metadata);

  quantized.codes.assign(gain_stops.size(), 0.0F);
  if (quantized.stored_gain_max > kEpsilon) {
    for (std::size_t i = 0; i < gain_stops.size(); ++i) {
      quantized.codes[i] = std::clamp(
          gain_stops[i] / quantized.stored_gain_max, 0.0F, 1.0F);
    }
  }
  const float gamma = quantized.stored_gain_max > kEpsilon
                          ? choose_gain_gamma(quantized.codes)
                          : 1.0F;
  quantized.gamma_metadata = rational_from_float(gamma);
  quantized.stored_gamma = rational_value(quantized.gamma_metadata);
  for (std::size_t i = 0; i < gain_stops.size(); ++i) {
    const float code = encode_gain_code(quantized.codes[i], quantized.stored_gamma);
    const auto x = static_cast<std::uint32_t>(i % width);
    const auto y = static_cast<std::uint32_t>(i / width);
    quantized.codes[i] = quantize_gain_code_dithered(code, x, y);
  }
  return quantized;
}

}  // namespace hyperdr
