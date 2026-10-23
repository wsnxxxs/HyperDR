#include "hyperdr/gainmap/reconstruct.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <optional>
#include <stdexcept>
#include <vector>

namespace hyperdr {

namespace {
void reconstruct(const FloatImage& base, const FloatImage& gain,
                                const GainMapMetadata& metadata,
                                float display_headroom_stops,
                                ReconstructionStats* stats, bool clamp_srgb, FloatImage* output,
                                RenderStats* rendition, std::span<const std::uint8_t> below_knee) {
  if (output == &base || output == &gain)
    throw std::invalid_argument("reconstruction output must not alias its inputs");
  validate_gain_map_metadata(metadata);
  const auto metadata_channels = gain_map_channel_count(metadata);
  if (base.channels != 3 ||
      (gain.channels != 1 && gain.channels != 3) ||
      gain.channels != metadata_channels) {
    throw std::invalid_argument(
        "reconstruction requires matching one- or three-channel gain metadata");
  }
  if (output && (output->width != base.width || output->height != base.height || output->channels != 3 ||
                 output->pixels.size() != static_cast<std::size_t>(base.width) * base.height * 3))
    *output = FloatImage(base.width, base.height, 3);
  std::vector<float> peaks(rendition ? base.height : 0, 1), differences(rendition ? base.height : 0, 0);
  // Accumulated per row, not into shared counters: the row loop runs in
  // parallel, and a clamp count that depends on thread interleaving would be
  // a diagnostic nobody could reproduce.
  std::vector<std::uint64_t> row_clamp_values(stats ? base.height : 0, 0);
  std::vector<std::uint64_t> row_clamp_pixels(stats ? base.height : 0, 0);
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alt_headroom = rational_value(metadata.alternate_headroom);
  const float denominator = alt_headroom - base_headroom;
  const float fraction = std::abs(denominator) < 1.0e-8F
                             ? 0.0F
                             : std::clamp((display_headroom_stops - base_headroom) / denominator, 0.0F, 1.0F);
  // ISO stores HDR/SDR log gain regardless of which rendition is the base.
  // A base with more headroom therefore applies that gain in reverse. The
  // fraction selects the endpoint; its sign selects the gain's direction.
  const float weight = denominator < 0.0F ? -fraction : fraction;
  // At matching dimensions the half-pixel grid selects the exact same texel.
  // Bound the shortcut so all old double coordinate products are exact too.
  const bool identity_grid = base.width > 0 && base.height > 0 &&
                             gain.width == base.width && gain.height == base.height &&
                             base.width <= 65536 && base.height <= 65536;
  std::optional<BilinearGridSampler> sampler;
  if (!identity_grid) sampler.emplace(gain.width, gain.height, base.width, base.height);
  struct Channel {
    float min_gain, max_gain, inverse_gamma, base_offset, alt_offset;
  };
  std::array<Channel, 3> channels{};
  for (unsigned c = 0; c < gain.channels; ++c) {
    const auto channel = gain_map_channel(metadata, c);
    channels[c] = {rational_value(channel.gain_min), rational_value(channel.gain_max),
                   1.0F / rational_value(channel.gamma),
                   rational_value(channel.base_offset), rational_value(channel.alternate_offset)};
  }
  parallel_for_rows(base.height, [&](const std::uint32_t y) {
    for (std::uint32_t x = 0; x < base.width; ++x) {
      const auto coordinates = identity_grid ? BilinearGridCoordinates{x, x, y, y, 0, 0} : sampler->coordinates(x, y);
      bool pixel_clamped = false;
      std::array<float, 3> multipliers{};
      // A monochrome gain map has one multiplier shared by RGB; decode it
      // once, while retaining the independent-channel path for imported maps.
      for (unsigned gain_channel = 0; gain_channel < gain.channels; ++gain_channel) {
        const auto& channel = channels[gain_channel];
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
        const float log_gain =
            std::lerp(channel.min_gain, channel.max_gain,
                      std::pow(encoded, channel.inverse_gamma));
        multipliers[gain_channel] = std::exp2(log_gain * weight);
      }
      std::array<float, 3> rgb{};
      for (unsigned c = 0; c < 3; ++c) {
        const auto gain_channel = gain.channels == 1 ? 0U : c;
        const auto& channel = channels[gain_channel];
        const float reconstructed = (base.at(x, y, c) + channel.base_offset) *
                                        multipliers[gain_channel] - channel.alt_offset;
        if (stats && reconstructed < 0.0F) {
          ++row_clamp_values[y];
          pixel_clamped = true;
        }
        rgb[c] = std::max(0.0F, reconstructed);
      }
      if (clamp_srgb) {
        const auto fitted = compress_linear_p3_to_srgb(
            rgb[0], rgb[1], rgb[2], true);
        rgb = fitted;
      }
      if (output) for (unsigned c = 0; c < 3; ++c) output->at(x, y, c) = rgb[c];
      if (rendition) {
        const float alternate = p3_luminance(rgb[0], rgb[1], rgb[2]);
        peaks[y] = std::max(peaks[y], alternate);
        const auto pixel = static_cast<std::size_t>(y) * base.width + x;
        if (!below_knee.empty() && below_knee[pixel]) {
          const float sdr = p3_luminance(base.at(x,y,0), base.at(x,y,1), base.at(x,y,2));
          differences[y] = std::max(differences[y], std::abs(alternate-sdr)/std::max(sdr,kEpsilon));
        }
      }
      if (stats && pixel_clamped) ++row_clamp_pixels[y];
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
  if (rendition) {
    rendition->rendered_peak = *std::max_element(peaks.begin(), peaks.end());
    rendition->headroom_utilization = rendition->headroom_linear > 1
        ? std::clamp((rendition->rendered_peak-1)/(rendition->headroom_linear-1),0.0F,1.0F) : 0;
    if (!below_knee.empty()) rendition->below_knee_relative_difference_max =
        *std::max_element(differences.begin(), differences.end());
  }
}
}  // namespace

void reconstruct_gain_map_into(FloatImage& output, const FloatImage& base,
    const FloatImage& gain, const GainMapMetadata& metadata, float display_headroom_stops,
    ReconstructionStats* stats, bool clamp_srgb) {
  reconstruct(base, gain, metadata, display_headroom_stops, stats, clamp_srgb, &output, nullptr, {});
}

FloatImage reconstruct_gain_map(const FloatImage& base, const FloatImage& gain,
    const GainMapMetadata& metadata, float display_headroom_stops,
    ReconstructionStats* stats, bool clamp_srgb) {
  FloatImage output;
  reconstruct(base, gain, metadata, display_headroom_stops, stats, clamp_srgb, &output, nullptr, {});
  return output;
}

void measure_reconstructed_rendition_stats(RenderStats& stats,
    const FloatImage& base, const FloatImage& gain, const GainMapMetadata& metadata,
    float display_headroom_stops, std::span<const std::uint8_t> below_knee, bool clamp_srgb) {
  reconstruct(base, gain, metadata, display_headroom_stops, nullptr, clamp_srgb, nullptr, &stats, below_knee);
}

}  // namespace hyperdr
