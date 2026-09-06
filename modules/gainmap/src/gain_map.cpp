#include "hyperdr/gainmap/gain_map.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/gainmap/display_referred.hpp"
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
      const float r = finite_or_zero(source.pixels[base]);
      const float g = finite_or_zero(source.pixels[base + 1]);
      const float b = finite_or_zero(source.pixels[base + 2]);
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
  validate_render_options(options);
}

float nominal_headroom_stops(const GainMapOptions& options) {
  const float requested = options.auto_headroom ? options.look.headroom_max_stops
                                                : options.headroom_stops;
  return look_headroom_ceiling_stops(options.look.mode, requested);
}

GainMapResult make_gain_map(const FloatImage& source, const GainMapOptions& options,
                            const CaptureMetadata& capture,
                            const InputDescription& input,
                            const PhotographicAnalysis* analysis, GainMapPreparation* preparation) {
  validate_gain_map_options(options);
  validate_input_description(input);
  if (source.channels != 3) throw std::invalid_argument("gain-map input must be RGB");
  // Measure the decoded P3 source before exposure or the renderer mutates its
  // colour. This makes the report a property of the capture rather than of the
  // grade.
  const auto wide_gamut = preparation && preparation->ready
      ? WideGamutMeasurement{preparation->base_stats.wide_gamut_pixels,
                             preparation->base_stats.wide_gamut_eligible_pixels}
      : measure_wide_gamut_input(source);
  // The one place the three domains part company. The photographic renderer
  // below is scene-referred throughout -- it chooses an exposure from the
  // scene's log average and lands on a toe/linear/shoulder curve -- and running
  // it over a finished photograph re-develops someone else's picture. Which
  // renderer applies is decided by what the decoder produced, never by the
  // file's extension.
  auto result = [&]() -> GainMapResult {
    switch (input.domain) {
      case InputDomain::kDisplayReferredSdr:
        return make_display_referred_sdr_result(source, options, capture, preparation);
      case InputDomain::kDisplayReferredHdr:
        return make_display_referred_hdr_gain_map(source, options,
                                                  input.headroom);
      case InputDomain::kSceneReferred:
        break;
      case InputDomain::kUnknown:
        throw std::invalid_argument("cannot render an unknown input domain");
    }
    return make_photographic_gain_map(source, options, capture, analysis, preparation);
  }();
  result.clamp_srgb = options.clamp_srgb;
  set_wide_gamut_stats(result.stats, wide_gamut);
  if (preparation) set_wide_gamut_stats(preparation->base_stats, wide_gamut);
  return result;
}

}  // namespace hyperdr
