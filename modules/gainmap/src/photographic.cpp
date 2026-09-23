#include "hyperdr/gainmap/gain_map.hpp"
#include "local_gain.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/render.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/grid.hpp"
#include "hyperdr/look/tone_curve.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <utility>
#include <vector>

namespace hyperdr {
GainMapResult make_photographic_gain_map(const FloatImage& source,
                                         const GainMapOptions& options,
                                         const CaptureMetadata& capture,
                                         const PhotographicAnalysis* cached_analysis,
                                         GainMapPreparation* preparation) {
  if (source.channels != 3)
    throw std::invalid_argument("gain-map input must be RGB");
  validate_gain_map_options(options);


  GainMapPreparation owned_preparation;
  auto& prepared = preparation ? *preparation : owned_preparation;
  prepare_photographic_render(source, options, capture, cached_analysis, prepared);
  const GainGridDimensions dimensions{prepared.width, prepared.height};
  const float exposure_ev = prepared.exposure_ev;
  const float exposure = std::exp2(exposure_ev);
  const float requested_headroom_stops = prepared.requested_stops;
  const auto ev100 = estimate_ev100(capture);
  const float target_middle_gray = compute_target_middle_gray(ev100);
  auto gain = prepared.stops;
  const float photographic_strength = std::min(options.gain_strength, 1.0F);
  const float target_headroom_stops = requested_headroom_stops * photographic_strength;
  const float target_peak = std::exp2(target_headroom_stops);
  // A range is a budget, not a requirement to brighten some cell to its limit.
  // Multiplication preserves the local/noise attenuation and makes strength
  // independent of the brightest cell elsewhere in the photograph.
  for (float& value : gain) value *= photographic_strength;

  // --- Encode gain map ---
  auto quantized = quantize_gain_grid(gain, dimensions.width);
  const auto stored_gain_max_metadata = quantized.gain_max_metadata;
  const auto stored_gamma_metadata = quantized.gamma_metadata;
  const float stored_gain_max = quantized.stored_gain_max;
  const float stored_gamma = quantized.stored_gamma;

  GainMapResult result;
  result.gain_map =
      FloatImage(dimensions.width, dimensions.height, 1);
  result.gain_map.pixels = std::move(quantized.codes);

  // --- Full-resolution render ---
  render_full_resolution(source, exposure, prepared.local_average, dimensions.width,
                         dimensions.height, stored_gain_max, stored_gamma,
                         target_peak, options.look, options.clamp_srgb, result, preparation ? &prepared.base : nullptr);

  // --- Populate remaining metadata and stats ---
  result.metadata.gain_min = {0, 1};
  result.metadata.gain_max = stored_gain_max_metadata;
  result.metadata.gamma = stored_gamma_metadata;
  result.metadata.base_offset = {0, 1};
  result.metadata.alternate_offset = {0, 1};
  result.metadata.base_headroom = {0, 1};
  // Keep HyperDR's Apple-targeted output in the same single-channel profile as
  // the native Apple corpus. Generic ISO readers still accept independent
  // fields, but our writer never emits that less-interoperable form.
  result.metadata.alternate_headroom = stored_gain_max_metadata;
  result.exposure_ev = exposure_ev;
  result.headroom_stops = stored_gain_max;

  auto& stats = result.stats;
  stats.exposure_ev = exposure_ev;
  stats.ev100 = ev100;
  stats.target_middle_gray = target_middle_gray;
  stats.headroom_stops = target_headroom_stops;
  stats.headroom_linear = target_peak;
  stats.gain_min_stops = 0.0F;
  stats.gain_max_stops = stored_gain_max;
  stats.gain_gamma = stored_gamma;

  measure_quantized_gain(stats, result.gain_map, stored_gain_max, stored_gamma,
                          target_headroom_stops);
  stats.local_weight_mean = prepared.weight_mean;
  stats.local_weight_p95 = prepared.weight_p95;

  return result;
}

}  // namespace hyperdr
