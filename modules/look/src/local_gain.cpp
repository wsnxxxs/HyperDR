#include "hyperdr/look/local_gain.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/filter.hpp"

#include <algorithm>
#include <cmath>
#include <numeric>

namespace hyperdr {
namespace {

struct Environment {
  GainGridDimensions dimensions;
  std::vector<float> log_mean, log_second_moment, sdr_mean;
};

Environment analyze_environment(const std::vector<float>& log_scene,
                                const std::vector<float>& sdr_guide,
                                GainGridDimensions fine) {
  // Only broad environment statistics are reduced. Gain requests and the
  // edge-aware filter stay on the fine grid, including isolated highlights.
  constexpr std::uint32_t kAnalysisEdge = 768;
  Environment env;
  const auto edge = std::max(fine.width, fine.height);
  const auto scaled = [&](std::uint32_t extent) {
    return std::max(1U, static_cast<std::uint32_t>(
        (static_cast<std::uint64_t>(extent) * kAnalysisEdge + edge / 2) / edge));
  };
  env.dimensions = edge <= kAnalysisEdge ? fine : GainGridDimensions{scaled(fine.width), scaled(fine.height)};
  const auto [width, height] = env.dimensions;
  const auto count = static_cast<std::size_t>(width) * height;
  std::vector<float> mean(count), second(count), sdr(count);
  parallel_for_rows(height, [&](std::uint32_t y) {
    const auto y0 = grid_cell_edge(y, fine.height, height);
    const auto y1 = grid_cell_edge(y + 1, fine.height, height);
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto x0 = grid_cell_edge(x, fine.width, width);
      const auto x1 = grid_cell_edge(x + 1, fine.width, width);
      double sum = 0, sum_squared = 0, sdr_sum = 0;
      for (auto fy = y0; fy < y1; ++fy) for (auto fx = x0; fx < x1; ++fx) {
        const auto i = static_cast<std::size_t>(fy) * fine.width + fx;
        const float value = log_scene[i];
        sum += value;
        // Reduce the second moment itself, not the square of a reduced mean:
        // otherwise the noise/texture variance would disappear at this step.
        sum_squared += value * value;
        sdr_sum += sdr_guide[i];
      }
      const auto i = static_cast<std::size_t>(y) * width + x;
      const auto samples = (x1 - x0) * (y1 - y0);
      mean[i] = static_cast<float>(sum / samples);
      second[i] = static_cast<float>(sum_squared / samples);
      sdr[i] = static_cast<float>(sdr_sum / samples);
    }
  });
  env.log_mean.resize(count);
  env.log_second_moment.resize(count);
  env.sdr_mean.resize(count);
  std::vector<double> integral((static_cast<std::size_t>(width) + 1) * (height + 1));
  const auto radius = std::clamp<std::uint32_t>(std::min(width, height) * 3U / 100U, 4U, 64U);
  box_mean(mean, env.log_mean, width, height, radius, integral);
  box_mean(second, env.log_second_moment, width, height, radius, integral);
  box_mean(sdr, env.sdr_mean, width, height, radius, integral);
  return env;
}

}  // namespace

LocalGain weight_local_highlights(const std::vector<float>& global_gain,
                                 const std::vector<float>& scene_luma,
                                 const std::vector<float>& sdr_guide,
                                 GainGridDimensions dimensions,
                                 const CaptureMetadata& capture,
                                 const LookOptions& look) {
  const auto count = global_gain.size();
  LocalGain result;
  result.stops.resize(count);
  result.local_average.resize(count);
  std::vector<float> variance(count), work_one(count), work_two(count);
  std::vector<double> integral((static_cast<std::size_t>(dimensions.width) + 1) *
                              (static_cast<std::size_t>(dimensions.height) + 1));
  for (std::size_t i = 0; i < count; ++i) {
    // The noise statistic needs no values below -8 EV. Bounding before
    // squaring also keeps both moments inside box_mean's supported range.
    result.stops[i] = std::clamp(std::log2(scene_luma[i] + kEpsilon), -8.0F, 8.0F);
  }
  auto env = analyze_environment(result.stops, sdr_guide, dimensions);
  const bool same_grid = env.dimensions.width == dimensions.width && env.dimensions.height == dimensions.height;
  const GridView mean_view(env.log_mean, env.dimensions.width, env.dimensions.height);
  const GridView second_view(env.log_second_moment, env.dimensions.width, env.dimensions.height);
  const GridView sdr_view(env.sdr_mean, env.dimensions.width, env.dimensions.height);
  const BilinearGridSampler sampler(env.dimensions.width, env.dimensions.height,
                                    dimensions.width, dimensions.height);
  const float floor = std::clamp(look.diffuse_gain_floor + 0.20F * look.pop, 0.0F, 1.0F);
  const float iso = capture.iso && std::isfinite(*capture.iso) && *capture.iso > 0.0F
      ? smoothstep(800.0F, 25600.0F, *capture.iso) : 0.35F;
  parallel_for_rows(dimensions.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < dimensions.width; ++x) {
      const auto i = static_cast<std::size_t>(y) * dimensions.width + x;
      const float mean = same_grid ? env.log_mean[i] : sampler.sample(mean_view, x, y);
      const float contrast = result.stops[i] - mean;
      const float specular = smoothstep(1.0F, 2.5F, contrast);
      const float absolute = smoothstep(0.70F, 1.50F, sdr_guide[i] * std::exp2(global_gain[i]));
      const float second = same_grid ? env.log_second_moment[i] : sampler.sample(second_view, x, y);
      const float local_var = std::max(0.0F, second - mean * mean);
      const float noise = iso * (1.0F - smoothstep(0.03F, 0.20F, sdr_guide[i])) *
                          smoothstep(0.005F, 0.07F, local_var);
      work_one[i] = std::clamp((floor + (1.0F - floor) * specular * absolute) *
                              (1.0F - noise), 0.0F, 1.0F);
      result.stops[i] = global_gain[i] * work_one[i];
    }
  });
  const double weight_sum = std::accumulate(work_one.begin(), work_one.end(), 0.0);
  result.weight_mean = count ? static_cast<float>(weight_sum / count) : 1.0F;
  result.weight_p95 = percentile(work_one, 0.95F);
  guided_filter_gain(result.stops, global_gain, sdr_guide, dimensions.width,
                     dimensions.height, result.local_average, variance,
                     work_one, work_two, integral);
  if (same_grid) {
    result.local_average = std::move(env.sdr_mean);
  } else {
    parallel_for_rows(dimensions.height, [&](std::uint32_t y) {
      for (std::uint32_t x = 0; x < dimensions.width; ++x)
        result.local_average[static_cast<std::size_t>(y) * dimensions.width + x] = sampler.sample(sdr_view, x, y);
    });
  }
  return result;
}

}  // namespace hyperdr
