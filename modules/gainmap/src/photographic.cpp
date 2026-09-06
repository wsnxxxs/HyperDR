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
PhotographicAnalysis analyze_photographic_source(const FloatImage& source) {
  source.require_consistent("photographic analysis input");
  if (source.channels != 3) throw std::invalid_argument("photographic analysis requires RGB");
  PhotographicAnalysis inputs;
  inputs.scene_stats = compute_luminance_statistics(source);
  inputs.dimensions = choose_gain_dimensions(source);
  const std::size_t count = static_cast<std::size_t>(inputs.dimensions.width) *
                            inputs.dimensions.height;
  inputs.cell_mean.assign(count, 0.0F);
  inputs.cell_peak.assign(count, 0.0F);
  parallel_for_rows(inputs.dimensions.height, [&](const std::uint32_t gy) {
    const std::uint32_t y0 =
        grid_cell_edge(gy, source.height, inputs.dimensions.height);
    const std::uint32_t y1 = std::min(
        source.height,
        std::max(y0 + 1U,
                 grid_cell_edge(gy + 1U, source.height,
                                inputs.dimensions.height)));
    for (std::uint32_t gx = 0; gx < inputs.dimensions.width; ++gx) {
      const std::uint32_t x0 =
          grid_cell_edge(gx, source.width, inputs.dimensions.width);
      const std::uint32_t x1 = std::min(
          source.width,
          std::max(x0 + 1U,
                   grid_cell_edge(gx + 1U, source.width,
                                  inputs.dimensions.width)));
      double total = 0.0;
      float peak = 0.0F;
      std::size_t samples = 0;
      for (std::uint32_t y = y0; y < y1; ++y) {
        for (std::uint32_t x = x0; x < x1; ++x) {
          const std::size_t index =
              (static_cast<std::size_t>(y) * source.width + x) * 3;
          const float value =
              p3_luminance(positive_finite(source.pixels[index]),
                           positive_finite(source.pixels[index + 1]),
                           positive_finite(source.pixels[index + 2]));
          total += value;
          peak = std::max(peak, value);
          ++samples;
        }
      }
      const std::size_t index =
          static_cast<std::size_t>(gy) * inputs.dimensions.width + gx;
      inputs.cell_mean[index] =
          samples == 0 ? 0.0F : static_cast<float>(total / samples);
      inputs.cell_peak[index] = peak;
    }
  });
  return inputs;
}

namespace {

float select_exposure_ev(const PhotographicAnalysis& inputs,
                         const CaptureMetadata& capture,
                         const GainMapOptions& options,
                         const ToneCurveParameters& curve) {
  const auto ev100 = estimate_ev100(capture);
  const float target_middle_gray = compute_target_middle_gray(ev100);
  const float pop = std::clamp(options.look.pop, 0.0F, 1.0F);
  float exposure_ev = 0.0F;
  if (options.auto_exposure) {
    const float base_ev =
        std::log2(target_middle_gray /
                  std::max(inputs.scene_stats.log_average, kEpsilon));
    const float provisional_exposure_ev = clamp_finite(base_ev, -6.0F, 6.0F);
    const float provisional_exposure = std::exp2(provisional_exposure_ev);
    const float provisional_stops =
        options.auto_headroom
            ? choose_headroom_stops(
                  inputs.scene_stats, provisional_exposure, capture,
                  options.look.headroom_max_stops, inputs.cell_mean,
                  inputs.cell_peak, inputs.dimensions.width,
                  inputs.dimensions.height, pop)
            : std::clamp(options.headroom_stops, 0.0F,
                         options.look.headroom_max_stops);
    const float highlight_limit = highlight_limited_exposure(
        inputs.scene_stats.p995, std::exp2(provisional_stops), curve);
    exposure_ev = std::min(provisional_exposure_ev, highlight_limit);
    if (ev100 && *ev100 < 8.0F) {
      exposure_ev =
          std::min(exposure_ev, options.look.positive_exposure_limit_ev);
    }
    exposure_ev = clamp_finite(exposure_ev, -6.0F, 6.0F);
  } else {
    exposure_ev = clamp_finite(options.exposure_ev, -10.0F, 10.0F);
  }
  return clamp_finite(exposure_ev + options.exposure_bias_ev, -10.0F, 10.0F);
}

}  // namespace

float photographic_exposure_ev(const FloatImage& source,
                               const GainMapOptions& options,
                               const CaptureMetadata& capture) {
  if (source.channels != 3)
    throw std::invalid_argument("photographic exposure input must be RGB");
  validate_gain_map_options(options);
  const auto inputs = analyze_photographic_source(source);
  return select_exposure_ev(inputs, capture, options, build_tone_curve(options.look));
}

GainMapResult make_photographic_gain_map(const FloatImage& source,
                                         const GainMapOptions& options,
                                         const CaptureMetadata& capture,
                                         const PhotographicAnalysis* cached_analysis,
                                         GainMapPreparation* preparation) {
  if (source.channels != 3)
    throw std::invalid_argument("gain-map input must be RGB");
  validate_gain_map_options(options);

  const ToneCurveParameters curve = build_tone_curve(options.look);
  const float pop = std::clamp(options.look.pop, 0.0F, 1.0F);

  GainMapPreparation owned_preparation;
  auto& prepared = preparation ? *preparation : owned_preparation;
  if (!prepared.ready) {
    // --- Scene analysis, exposure metadata, and gain-grid sampling ---
    const auto owned_analysis = cached_analysis ? PhotographicAnalysis{} : analyze_photographic_source(source);
    const auto& inputs = cached_analysis ? *cached_analysis : owned_analysis;
    const auto expected = choose_gain_dimensions(source);
    const auto count = static_cast<std::size_t>(expected.width) * expected.height;
    if (inputs.dimensions.width != expected.width || inputs.dimensions.height != expected.height ||
        inputs.cell_mean.size() != count || inputs.cell_peak.size() != count)
      throw std::invalid_argument("photographic analysis dimensions do not match the source");
    const auto& scene_stats = inputs.scene_stats;
    const GainGridDimensions dimensions = inputs.dimensions;
    const std::size_t gain_count =
        static_cast<std::size_t>(dimensions.width) * dimensions.height;

    // --- Exposure selection ---
    const float exposure_ev = select_exposure_ev(inputs, capture, options, curve);

    // The cell means and peaks are reused by the headroom and gain-map stages.
    std::vector<float> scene_luma = inputs.cell_mean;
    const auto& highlight_peak = inputs.cell_peak;
    const float exposure = std::exp2(exposure_ev);

    // --- Headroom selection ---
    const float requested_headroom_stops =
        options.auto_headroom
            ? choose_headroom_stops(
                  scene_stats, exposure, capture,
                  options.look.headroom_max_stops, scene_luma, highlight_peak,
                  dimensions.width, dimensions.height, pop)
            : std::clamp(options.headroom_stops, 0.0F,
                         options.look.headroom_max_stops);
    const float requested_headroom_linear = std::exp2(requested_headroom_stops);

    // Average the gain requested by each pixel, not the gain of its cell mean:
    // a small specular must not disappear into the dark pixels surrounding it.
    std::vector<float> global_gain(gain_count, 0.0F);
    std::vector<float> sdr_guide(gain_count, 0.0F);
    parallel_for_rows(dimensions.height, [&](const std::uint32_t gy) {
      const auto y0 = grid_cell_edge(gy, source.height, dimensions.height);
      const auto y1 = grid_cell_edge(gy + 1U, source.height, dimensions.height);
      for (std::uint32_t gx = 0; gx < dimensions.width; ++gx) {
        const auto x0 = grid_cell_edge(gx, source.width, dimensions.width);
        const auto x1 = grid_cell_edge(gx + 1U, source.width, dimensions.width);
        double gain_sum = 0.0, guide_sum = 0.0;
        for (auto y = y0; y < y1; ++y) {
          for (auto x = x0; x < x1; ++x) {
            const auto px = (static_cast<std::size_t>(y) * source.width + x) * 3;
            const float scene = p3_luminance(positive_finite(source.pixels[px]),
                positive_finite(source.pixels[px + 1]),
                positive_finite(source.pixels[px + 2])) * exposure;
            const float sdr = render_tone_curve(scene, 1.0F, curve);
            guide_sum += sdr;
            if (scene > curve.shoulder_input) {
              const float hdr = render_tone_curve(scene, requested_headroom_linear, curve);
              gain_sum += std::max(0.0F, std::log2((hdr + kEpsilon) / (sdr + kEpsilon)));
            }
          }
        }
        const auto i = static_cast<std::size_t>(gy) * dimensions.width + gx;
        const auto samples = (x1 - x0) * (y1 - y0);
        global_gain[i] = samples ? static_cast<float>(gain_sum / samples) : 0.0F;
        sdr_guide[i] = samples ? static_cast<float>(guide_sum / samples) : 0.0F;
        scene_luma[i] *= exposure;
      }
    });
    auto local_gain = weight_local_highlights(global_gain, scene_luma, sdr_guide,
                                             dimensions, capture, options.look);
    prepared.width = dimensions.width; prepared.height = dimensions.height;
    prepared.exposure_ev = exposure_ev; prepared.requested_stops = requested_headroom_stops;
    prepared.stops = std::move(local_gain.stops);
    prepared.local_average = std::move(local_gain.local_average);
    prepared.weight_mean = local_gain.weight_mean; prepared.weight_p95 = local_gain.weight_p95;
    prepared.ready = true;
  }
  const GainGridDimensions dimensions{prepared.width, prepared.height};
  const auto gain_count = prepared.stops.size();
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
  float gain_max = 0.0F;
  for (const float value : gain) gain_max = std::max(gain_max, value);
  std::vector<float> normalized_gains(gain_count, 0.0F);
  if (gain_max > kEpsilon) {
    for (std::size_t i = 0; i < gain_count; ++i) {
      normalized_gains[i] = std::clamp(gain[i] / gain_max, 0.0F, 1.0F);
    }
  }
  const float gamma =
      gain_max > kEpsilon ? choose_gain_gamma(normalized_gains) : 1.0F;
  const Rational stored_gain_max_metadata = rational_from_float(gain_max);
  const Rational stored_gamma_metadata = rational_from_float(gamma);
  const float stored_gain_max =
      static_cast<float>(stored_gain_max_metadata.numerator) /
      stored_gain_max_metadata.denominator;
  const float stored_gamma =
      static_cast<float>(stored_gamma_metadata.numerator) /
      stored_gamma_metadata.denominator;

  GainMapResult result;
  result.gain_map =
      FloatImage(dimensions.width, dimensions.height, 1);
  for (std::uint32_t y = 0; y < dimensions.height; ++y) {
    for (std::uint32_t x = 0; x < dimensions.width; ++x) {
      const std::size_t index =
          static_cast<std::size_t>(y) * dimensions.width + x;
      const float code =
          encode_gain_code(normalized_gains[index], stored_gamma);
      result.gain_map.at(x, y, 0) =
          quantize_gain_code_dithered(code, x, y);
    }
  }

  // --- Full-resolution render ---
  render_full_resolution(source, exposure, prepared.local_average, dimensions.width,
                         dimensions.height, stored_gain_max, stored_gamma,
                         target_peak, options.look, result, preparation ? &prepared.base : nullptr);

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
