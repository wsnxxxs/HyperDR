#include "hyperdr/gainmap/gain_map.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/render.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/filter.hpp"
#include "hyperdr/look/grid.hpp"
#include "hyperdr/look/tone_curve.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

struct ExposureInputs {
  SceneStatistics scene_stats;
  CaptureMetadata capture;
  std::optional<float> ev100;
  float target_middle_gray{0.18F};
  GainGridDimensions dimensions;
  std::vector<float> cell_mean;
  std::vector<float> cell_peak;
};

ExposureInputs build_exposure_inputs(const FloatImage& source,
                                     const CaptureMetadata& capture) {
  ExposureInputs inputs;
  inputs.capture = capture;
  inputs.scene_stats = compute_luminance_statistics(source);
  inputs.ev100 = estimate_ev100(capture);
  inputs.target_middle_gray = compute_target_middle_gray(inputs.ev100);
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

float select_exposure_ev(const ExposureInputs& inputs,
                         const GainMapOptions& options,
                         const ToneCurveParameters& curve) {
  const float pop = std::clamp(options.look.pop, 0.0F, 1.0F);
  float exposure_ev = 0.0F;
  if (options.auto_exposure) {
    const float base_ev =
        std::log2(inputs.target_middle_gray /
                  std::max(inputs.scene_stats.log_average, kEpsilon));
    const float provisional_exposure_ev = clamp_finite(base_ev, -6.0F, 6.0F);
    const float provisional_exposure = std::exp2(provisional_exposure_ev);
    const float provisional_stops =
        options.auto_headroom
            ? choose_headroom_stops(
                  inputs.scene_stats, provisional_exposure, inputs.capture,
                  options.look.headroom_max_stops, inputs.cell_mean,
                  inputs.cell_peak, inputs.dimensions.width,
                  inputs.dimensions.height, pop)
            : std::clamp(options.headroom_stops, 0.0F,
                         options.look.headroom_max_stops);
    const float highlight_limit = highlight_limited_exposure(
        inputs.scene_stats.p995, std::exp2(provisional_stops), curve);
    exposure_ev = std::min(provisional_exposure_ev, highlight_limit);
    if (inputs.ev100 && *inputs.ev100 < 8.0F) {
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
  const auto inputs = build_exposure_inputs(source, capture);
  return select_exposure_ev(inputs, options, build_tone_curve(options.look));
}

GainMapResult make_photographic_gain_map(const FloatImage& source,
                                         const GainMapOptions& options,
                                         const CaptureMetadata& capture) {
  if (source.channels != 3)
    throw std::invalid_argument("gain-map input must be RGB");
  validate_gain_map_options(options);

  const ToneCurveParameters curve = build_tone_curve(options.look);
  const float pop = std::clamp(options.look.pop, 0.0F, 1.0F);
  const float diffuse_floor =
      std::clamp(options.look.diffuse_gain_floor + 0.20F * pop, 0.0F, 1.0F);

  // --- Scene analysis, exposure metadata, and gain-grid sampling ---
  auto inputs = build_exposure_inputs(source, capture);
  const auto& scene_stats = inputs.scene_stats;
  const auto& ev100 = inputs.ev100;
  const float target_middle_gray = inputs.target_middle_gray;
  const GainGridDimensions dimensions = inputs.dimensions;
  const std::size_t gain_count =
      static_cast<std::size_t>(dimensions.width) * dimensions.height;

  // --- Exposure selection ---
  const float exposure_ev = select_exposure_ev(inputs, options, curve);

  // The cell means and peaks are reused by the headroom and gain-map stages.
  std::vector<float> scene_luma = std::move(inputs.cell_mean);
  std::vector<float> highlight_peak = std::move(inputs.cell_peak);
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

  highlight_peak.clear();
  highlight_peak.shrink_to_fit();

  // --- Gain map core computation ---
  std::vector<float> global_gain(gain_count, 0.0F);
  std::vector<float> local(gain_count, 0.0F);
  std::vector<float> variance(gain_count, 0.0F);
  std::vector<float> gain(gain_count, 0.0F);
  std::vector<float> work_one(gain_count, 0.0F);
  std::vector<float> work_two(gain_count, 0.0F);
  std::vector<double> integral(
      (static_cast<std::size_t>(dimensions.width) + 1) *
          (static_cast<std::size_t>(dimensions.height) + 1),
      0.0);

  const float photographic_strength = std::min(options.gain_strength, 1.0F);
  for (std::size_t i = 0; i < gain_count; ++i) {
    scene_luma[i] *= exposure;
    const float sdr = render_tone_curve(scene_luma[i], 1.0F, curve);
    const float hdr =
        render_tone_curve(scene_luma[i], requested_headroom_linear, curve);
    global_gain[i] =
        scene_luma[i] <= curve.shoulder_input
            ? 0.0F
            : std::max(0.0F, std::log2((hdr + kEpsilon) / (sdr + kEpsilon)));
    gain[i] = std::log2(scene_luma[i] + kEpsilon);
  }

  const std::uint32_t environment_radius = std::clamp<std::uint32_t>(
      std::min(dimensions.width, dimensions.height) * 3U / 100U, 4U, 64U);
  box_mean(gain, local, dimensions.width, dimensions.height,
           environment_radius, integral);
  for (std::size_t i = 0; i < gain_count; ++i) gain[i] *= gain[i];
  box_mean(gain, variance, dimensions.width, dimensions.height,
           environment_radius, integral);

  double weight_sum = 0.0;
  for (std::size_t i = 0; i < gain_count; ++i) {
    const float scene = scene_luma[i];
    const float sdr = render_tone_curve(scene, 1.0F, curve);
    const float hdr_global = sdr * std::exp2(global_gain[i]);
    const float local_contrast = std::log2(
        (scene + kEpsilon) / (std::exp2(local[i]) + kEpsilon));
    const float specular = smoothstep(1.0F, 2.5F, local_contrast);
    const float absolute = smoothstep(0.70F, 1.50F, hdr_global);
    float weight =
        diffuse_floor + (1.0F - diffuse_floor) * specular * absolute;
    const float local_var =
        std::max(0.0F, variance[i] - local[i] * local[i]);
    const float iso_term =
        capture.iso && std::isfinite(*capture.iso) && *capture.iso > 0.0F
            ? smoothstep(800.0F, 25600.0F, *capture.iso)
            : 0.35F;
    const float dark_term = 1.0F - smoothstep(0.03F, 0.20F, sdr);
    const float var_term = smoothstep(0.005F, 0.07F, local_var);
    const float noise_risk = iso_term * dark_term * var_term;
    weight = std::clamp(weight * (1.0F - noise_risk), 0.0F, 1.0F);
    variance[i] = weight;
    weight_sum += weight;
    gain[i] = weight * global_gain[i];
    scene_luma[i] = sdr;
  }

  const float local_weight_mean =
      gain_count == 0
          ? 1.0F
          : static_cast<float>(weight_sum / static_cast<double>(gain_count));
  const float local_weight_p95 =
      percentile(variance, 0.95F);

  guided_filter_gain(gain, global_gain, scene_luma, dimensions.width,
                     dimensions.height, local, variance, work_one, work_two,
                     integral);

  for (std::size_t i = 0; i < gain_count; ++i) {
    const float support = smoothstep(
        curve.shoulder_output * 0.45F, curve.shoulder_output * 1.05F,
        scene_luma[i]);
    gain[i] = std::max(0.0F, gain[i]) * support;
  }

  // --- Calibration ---
  const float target_headroom_stops =
      requested_headroom_stops * photographic_strength;
  const float target_peak = std::exp2(target_headroom_stops);
  // Apple's ISO gain-map writer convention uses one ceiling for the encoded
  // log-gain range and the alternate rendition's headroom. Allowing a darker
  // SDR cell to demand another 1.5 stops made otherwise valid files diverge
  // from that convention and render differently in Apple decoders. Preserve
  // the requested endpoint by limiting the ratio the SDR/HDR pair asks the map
  // to carry.
  const float maximum_calibrated_gain = target_headroom_stops;

  if (target_headroom_stops <= kEpsilon) {
    std::fill(gain.begin(), gain.end(), 0.0F);
  } else {
    float gain_scale = std::numeric_limits<float>::infinity();
    for (std::size_t i = 0; i < gain_count; ++i) {
      if (!(scene_luma[i] > 0.0F)) continue;
      const float required_gain =
          target_headroom_stops - std::log2(scene_luma[i]);
      if (required_gain <= 0.0F) {
        gain_scale = 0.0F;
        break;
      }
      if (gain[i] > 0.0F && required_gain <= maximum_calibrated_gain) {
        gain_scale = std::min(gain_scale, required_gain / gain[i]);
      }
    }
    gain_scale = std::isfinite(gain_scale)
                     ? std::clamp(gain_scale, 0.0F, 32.0F)
                     : 32.0F;
    for (float& value : gain) {
      value = std::min(value * gain_scale, maximum_calibrated_gain);
    }
  }

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
  box_mean(scene_luma, local, dimensions.width, dimensions.height,
           environment_radius, integral);
  render_full_resolution(source, exposure, local, dimensions.width,
                         dimensions.height, stored_gain_max, stored_gamma,
                         target_peak, options.look, result);

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

  // Gain percentile distribution
  std::vector<float> stored_gains(gain_count, 0.0F);
  for (std::size_t i = 0; i < gain_count; ++i) {
    stored_gains[i] = stored_gain_max *
                      decode_gain_code(result.gain_map.pixels[i], stored_gamma);
  }
  for (const float value : stored_gains) {
    if (value > 0.5F) stats.gain_fraction_gt_0_5 += 1.0F;
    if (value > 1.0F) stats.gain_fraction_gt_1_0 += 1.0F;
    if (value > 2.0F) stats.gain_fraction_gt_2_0 += 1.0F;
  }
  std::sort(stored_gains.begin(), stored_gains.end());
  constexpr std::array<float, 8> fractions{0.50F, 0.75F, 0.90F, 0.95F,
                                             0.99F, 0.999F, 0.9999F, 1.0F};
  if (!stored_gains.empty()) {
    for (std::size_t i = 0; i < fractions.size(); ++i) {
      const auto index = static_cast<std::size_t>(
          fractions[i] * static_cast<float>(stored_gains.size() - 1));
      stats.gain_percentiles[i] = stored_gains[index];
    }
  }
  if (gain_count != 0) {
    const float count = static_cast<float>(gain_count);
    stats.gain_fraction_gt_0_5 /= count;
    stats.gain_fraction_gt_1_0 /= count;
    stats.gain_fraction_gt_2_0 /= count;
  }
  stats.gain_clipped_fraction = 0.0F;
  stats.local_weight_mean = local_weight_mean;
  stats.local_weight_p95 = local_weight_p95;

  return result;
}

}  // namespace hyperdr
