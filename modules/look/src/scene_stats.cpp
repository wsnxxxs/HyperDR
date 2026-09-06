#include "hyperdr/look/analysis.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <vector>

namespace hyperdr {

SceneStatistics compute_luminance_statistics(const FloatImage& source) {
  source.require_consistent("scene-statistics input");
  if (source.channels != 3) {
    throw std::invalid_argument("scene-statistics input must be RGB");
  }
  SceneStatistics stats;
  // Sample the same normalized image coordinates at every render resolution.
  // A flattened pixel stride aliases rows differently after a preview resize.
  constexpr std::uint32_t reference_edge = 512;
  const auto edge = std::max(source.width, source.height);
  const double scale = std::min(1.0, static_cast<double>(reference_edge) / edge);
  const auto width = std::max(1U, static_cast<std::uint32_t>(std::lround(source.width * scale)));
  const auto height = std::max(1U, static_cast<std::uint32_t>(std::lround(source.height * scale)));
  const BilinearGridSampler sampler(source.width, source.height, width, height);
  stats.samples.reserve(static_cast<std::size_t>(width) * height);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto p = sampler.coordinates(x, y);
      const auto luma = [&](std::uint32_t sx, std::uint32_t sy) {
        const auto i = (static_cast<std::size_t>(sy) * source.width + sx) * 3;
        return p3_luminance(positive_finite(source.pixels[i]),
            positive_finite(source.pixels[i+1]), positive_finite(source.pixels[i+2]));
      };
      const float value = std::lerp(std::lerp(luma(p.x0,p.y0), luma(p.x1,p.y0), p.tx),
          std::lerp(luma(p.x0,p.y1), luma(p.x1,p.y1), p.tx), p.ty);
      if (std::isfinite(value) && value > 0.0F) stats.samples.push_back(value);
    }
  }
  if (stats.samples.empty()) return stats;

  const float low = percentile(stats.samples, 0.001F);
  const float high = percentile(stats.samples, 0.999F);
  double log_sum = 0.0;
  for (const float value : stats.samples) {
    log_sum +=
        std::log(std::max(std::clamp(value, low, high), kEpsilon));
  }
  stats.log_average =
      static_cast<float>(std::exp(log_sum / stats.samples.size()));
  stats.p995 = percentile(stats.samples, 0.995F);
  stats.p9999 = percentile(stats.samples, 0.9999F);
  return stats;
}

}  // namespace hyperdr
