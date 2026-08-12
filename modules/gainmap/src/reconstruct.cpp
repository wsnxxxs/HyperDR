#include "hyperdr/gainmap/reconstruct.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace hyperdr {

FloatImage reconstruct_gain_map(const FloatImage& base, const FloatImage& gain,
                                const GainMapMetadata& metadata,
                                float display_headroom_stops,
                                ReconstructionStats* stats) {
  if (base.channels != 3 || gain.channels != 1) throw std::invalid_argument("invalid reconstruction images");
  FloatImage output(base.width, base.height, 3);
  std::vector<std::uint64_t> row_clamp_values(base.height, 0);
  std::vector<std::uint64_t> row_clamp_pixels(base.height, 0);
  const float min_gain = rational_value(metadata.gain_min);
  const float max_gain = rational_value(metadata.gain_max);
  const float gamma = rational_value(metadata.gamma);
  const float base_offset = rational_value(metadata.base_offset);
  const float alt_offset = rational_value(metadata.alternate_offset);
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alt_headroom = rational_value(metadata.alternate_headroom);
  const float denominator = alt_headroom - base_headroom;
  const float fraction = std::abs(denominator) < 1.0e-8F
                             ? 0.0F
                             : std::clamp((display_headroom_stops - base_headroom) / denominator, 0.0F, 1.0F);
  const float weight = std::copysign(fraction, denominator);
  parallel_for_rows(base.height, [&](const std::uint32_t y) {
    const float gy = std::clamp(
        (static_cast<float>(y) + 0.5F) * gain.height / base.height - 0.5F,
        0.0F, static_cast<float>(gain.height - 1));
    const auto y0 = static_cast<std::uint32_t>(std::floor(gy));
    const auto y1 = std::min(y0 + 1, gain.height - 1);
    const float wy = gy - static_cast<float>(y0);
    for (std::uint32_t x = 0; x < base.width; ++x) {
      const float gx = std::clamp(
          (static_cast<float>(x) + 0.5F) * gain.width / base.width - 0.5F,
          0.0F, static_cast<float>(gain.width - 1));
      const auto x0 = static_cast<std::uint32_t>(std::floor(gx));
      const auto x1 = std::min(x0 + 1, gain.width - 1);
      const float wx = gx - static_cast<float>(x0);
      const float top = std::lerp(gain.at(x0, y0, 0), gain.at(x1, y0, 0), wx);
      const float bottom = std::lerp(gain.at(x0, y1, 0), gain.at(x1, y1, 0), wx);
      const float encoded = clamp_finite(std::lerp(top, bottom, wy), 0.0F, 1.0F);
      const float log_gain = std::lerp(min_gain, max_gain,
                                       std::pow(encoded, 1.0F / std::max(gamma, 1.0e-6F)));
      bool pixel_clamped = false;
      for (unsigned c = 0; c < 3; ++c) {
        const float reconstructed =
            (base.at(x, y, c) + base_offset) * std::exp2(log_gain * weight) -
            alt_offset;
        if (reconstructed < 0.0F) {
          ++row_clamp_values[y];
          pixel_clamped = true;
        }
        output.at(x, y, c) = std::max(0.0F, reconstructed);
      }
      if (pixel_clamped) ++row_clamp_pixels[y];
    }
  });
  if (stats != nullptr) {
    stats->total_values = static_cast<std::uint64_t>(base.width) * base.height * 3U;
    stats->total_pixels = static_cast<std::uint64_t>(base.width) * base.height;
    stats->clamp_values = 0;
    stats->clamp_pixels = 0;
    for (const auto value : row_clamp_values) stats->clamp_values += value;
    for (const auto value : row_clamp_pixels) stats->clamp_pixels += value;
  }
  return output;
}

}  // namespace hyperdr
