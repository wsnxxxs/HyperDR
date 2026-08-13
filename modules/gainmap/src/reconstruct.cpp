#include "hyperdr/gainmap/reconstruct.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace hyperdr {

FloatImage reconstruct_gain_map(const FloatImage& base, const FloatImage& gain,
                                const GainMapMetadata& metadata,
                                float display_headroom_stops,
                                ReconstructionStats* stats) {
  validate_gain_map_metadata(metadata);
  const auto metadata_channels = gain_map_channel_count(metadata);
  if (base.channels != 3 ||
      (gain.channels != 1 && gain.channels != 3) ||
      gain.channels != metadata_channels) {
    throw std::invalid_argument(
        "reconstruction requires matching one- or three-channel gain metadata");
  }
  FloatImage output(base.width, base.height, 3);
  // Accumulated per row, not into shared counters: the row loop runs in
  // parallel, and a clamp count that depends on thread interleaving would be
  // a diagnostic nobody could reproduce.
  std::vector<std::uint64_t> row_clamp_values(base.height, 0);
  std::vector<std::uint64_t> row_clamp_pixels(base.height, 0);
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alt_headroom = rational_value(metadata.alternate_headroom);
  const float denominator = alt_headroom - base_headroom;
  const float fraction = std::abs(denominator) < 1.0e-8F
                             ? 0.0F
                             : std::clamp((display_headroom_stops - base_headroom) / denominator, 0.0F, 1.0F);
  // The division already accounts for a reverse base/alternate ordering: both
  // numerator and denominator are negative between the endpoints. Applying
  // the denominator's sign a second time inverted the gain map.
  const float weight = fraction;
  parallel_for_rows(base.height, [&](const std::uint32_t y) {
    for (std::uint32_t x = 0; x < base.width; ++x) {
      // Share the renderer's double-precision coordinate path. The former
      // inline float arithmetic selected a different gain cell once an image
      // was wider than float's exact-integer range.
      const auto coordinates = bilinear_grid_coordinates(
          gain.width, gain.height, base.width, base.height, x, y);
      bool pixel_clamped = false;
      for (unsigned c = 0; c < 3; ++c) {
        const auto gain_channel = gain.channels == 1 ? 0U : c;
        const auto channel = gain_map_channel(metadata, gain_channel);
        const float top =
            std::lerp(gain.at(coordinates.x0, coordinates.y0, gain_channel),
                      gain.at(coordinates.x1, coordinates.y0, gain_channel),
                      coordinates.tx);
        const float bottom =
            std::lerp(gain.at(coordinates.x0, coordinates.y1, gain_channel),
                      gain.at(coordinates.x1, coordinates.y1, gain_channel),
                      coordinates.tx);
        const float encoded =
            clamp_finite(std::lerp(top, bottom, coordinates.ty), 0.0F, 1.0F);
        const float min_gain = rational_value(channel.gain_min);
        const float max_gain = rational_value(channel.gain_max);
        const float gamma = rational_value(channel.gamma);
        const float base_offset = rational_value(channel.base_offset);
        const float alt_offset = rational_value(channel.alternate_offset);
        const float log_gain =
            std::lerp(min_gain, max_gain,
                      std::pow(encoded,
                               1.0F / std::max(gamma, 1.0e-6F)));
        const float reconstructed = (base.at(x, y, c) + base_offset) *
                                        std::exp2(log_gain * weight) -
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
