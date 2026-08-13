#include "hyperdr/look/analysis.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"

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
  const std::size_t pixel_count =
      static_cast<std::size_t>(source.width) * source.height;
  const std::size_t step = std::max<std::size_t>(1, pixel_count / 200000);
  stats.samples.reserve(pixel_count / step + 1);
  for (std::size_t i = 0; i < pixel_count; i += step) {
    const std::size_t base = i * 3;
    const float r = positive_finite(source.pixels[base]);
    const float g = positive_finite(source.pixels[base + 1]);
    const float b = positive_finite(source.pixels[base + 2]);
    const float y = p3_luminance(r, g, b);
    if (std::isfinite(y) && y > 0.0F) stats.samples.push_back(y);
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
