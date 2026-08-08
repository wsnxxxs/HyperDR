#include "hyperdr/gainmap/gain_map.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"

#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

constexpr float kWideGamutLuminanceThreshold = 0.02F;

struct WideGamutMeasurement {
  std::uint64_t pixels{};
  std::uint64_t eligible_pixels{};
};

WideGamutMeasurement measure_wide_gamut_input(const FloatImage& source) {
  std::vector<std::uint64_t> row_pixels(source.height, 0);
  std::vector<std::uint64_t> row_eligible(source.height, 0);
  parallel_for_rows(source.height, [&](const std::uint32_t y) {
    std::uint64_t pixels = 0;
    std::uint64_t eligible = 0;
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const std::size_t base = (static_cast<std::size_t>(y) * source.width + x) * 3;
      const float r = positive_finite(source.pixels[base]);
      const float g = positive_finite(source.pixels[base + 1]);
      const float b = positive_finite(source.pixels[base + 2]);
      if (p3_luminance(r, g, b) < kWideGamutLuminanceThreshold) continue;
      ++eligible;
      if (is_outside_rec709(r, g, b)) ++pixels;
    }
    row_pixels[y] = pixels;
    row_eligible[y] = eligible;
  });

  WideGamutMeasurement measurement;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    measurement.pixels += row_pixels[y];
    measurement.eligible_pixels += row_eligible[y];
  }
  return measurement;
}

void set_wide_gamut_stats(RenderStats& stats, const WideGamutMeasurement& measurement) {
  stats.wide_gamut_pixels = measurement.pixels;
  stats.wide_gamut_eligible_pixels = measurement.eligible_pixels;
  stats.wide_gamut_luminance_threshold = kWideGamutLuminanceThreshold;
  stats.wide_gamut_fraction = measurement.eligible_pixels == 0
      ? 0.0F
      : static_cast<float>(static_cast<double>(measurement.pixels) /
                           static_cast<double>(measurement.eligible_pixels));
}

}  // namespace

void validate_gain_map_options(const GainMapOptions& options) {
  if (!(std::isfinite(options.gain_strength) && options.gain_strength >= 0.0F &&
        options.gain_strength <= 2.0F)) {
    throw std::invalid_argument("gain strength must be in [0, 2]");
  }
  if (!options.auto_exposure && !std::isfinite(options.exposure_ev)) {
    throw std::invalid_argument("manual exposure must be finite");
  }
  if (!(std::isfinite(options.exposure_bias_ev) && options.exposure_bias_ev >= 0.0F &&
        options.exposure_bias_ev <= 2.0F)) {
    throw std::invalid_argument("exposure bias must be in [0, 2]");
  }
  validate_look_options(options.look);
  if (options.auto_headroom) return;
  // The photographic renderer treats headroom-max as a hard ceiling, so an
  // explicit target above it would silently be clamped instead of honoured.
  if (!(std::isfinite(options.headroom_stops) && options.headroom_stops >= 0.0F &&
        options.headroom_stops <= options.look.headroom_max_stops)) {
    throw std::invalid_argument(
        "manual photographic headroom must be in [0, headroom-max]");
  }
}

float nominal_headroom_stops(const GainMapOptions& options) {
  const float requested = options.auto_headroom ? options.look.headroom_max_stops
                                                : options.headroom_stops;
  return look_headroom_ceiling_stops(options.look.mode, requested);
}

GainMapResult make_gain_map(const FloatImage& source, const GainMapOptions& options,
                            const CaptureMetadata& capture) {
  validate_gain_map_options(options);
  if (source.channels != 3) throw std::invalid_argument("gain-map input must be RGB");
  // Measure the decoded P3 source before exposure or the renderer mutates its
  // colour. This makes the report a property of the capture rather than of the
  // grade.
  const auto wide_gamut = measure_wide_gamut_input(source);
  auto result = make_photographic_gain_map(source, options, capture);
  set_wide_gamut_stats(result.stats, wide_gamut);
  return result;
}

}  // namespace hyperdr
