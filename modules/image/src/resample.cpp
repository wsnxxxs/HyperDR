#include "hyperdr/image/resample.hpp"

#include "hyperdr/foundation/parallel.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace hyperdr {
namespace {

FloatImage halve(const FloatImage& source, bool reduce_width,
                 bool reduce_height) {
  FloatImage reduced(reduce_width ? source.width / 2U + source.width % 2U
                                  : source.width,
                     reduce_height ? source.height / 2U + source.height % 2U
                                   : source.height,
                     source.channels);
  parallel_for_rows(reduced.height, [&](const std::uint32_t y) {
    const std::uint32_t y0 = reduce_height ? y * 2U : y;
    const std::uint32_t y1 =
        std::min(source.height, y0 + (reduce_height ? 2U : 1U));
    for (std::uint32_t x = 0; x < reduced.width; ++x) {
      const std::uint32_t x0 = reduce_width ? x * 2U : x;
      const std::uint32_t x1 =
          std::min(source.width, x0 + (reduce_width ? 2U : 1U));
      const float count = static_cast<float>((x1 - x0) * (y1 - y0));
      for (std::uint32_t c = 0; c < source.channels; ++c) {
        float sum = 0.0F;
        for (std::uint32_t sy = y0; sy < y1; ++sy) {
          for (std::uint32_t sx = x0; sx < x1; ++sx) sum += source.at(sx, sy, c);
        }
        reduced.at(x, y, c) = sum / count;
      }
    }
  });
  return reduced;
}

}  // namespace

FloatImage resample_to(FloatImage source, std::uint32_t width, std::uint32_t height) {
  if (width == 0 || height == 0) throw std::invalid_argument("resample target must be non-empty");
  if (source.width == width && source.height == height) return source;

  // Low-pass first so the bilinear step below never undersamples.
  while (true) {
    const bool reduce_width = source.width > 1U && source.width / 2U > width;
    const bool reduce_height = source.height > 1U && source.height / 2U > height;
    if (!reduce_width && !reduce_height) break;
    source = halve(source, reduce_width, reduce_height);
  }
  if (source.width == width && source.height == height) return source;

  FloatImage out(width, height, source.channels);
  const auto& in = source;
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const double sy = std::clamp(
        (static_cast<double>(y) + 0.5) * static_cast<double>(in.height) /
                static_cast<double>(height) - 0.5,
        0.0, static_cast<double>(in.height - 1U));
    const auto y0 = std::min(static_cast<std::uint32_t>(std::floor(sy)), in.height - 1U);
    const auto y1 = std::min(y0 + 1U, in.height - 1U);
    const float wy = static_cast<float>(sy - static_cast<double>(y0));
    for (std::uint32_t x = 0; x < width; ++x) {
      const double sx = std::clamp(
          (static_cast<double>(x) + 0.5) * static_cast<double>(in.width) /
                  static_cast<double>(width) - 0.5,
          0.0, static_cast<double>(in.width - 1U));
      const auto x0 = std::min(static_cast<std::uint32_t>(std::floor(sx)), in.width - 1U);
      const auto x1 = std::min(x0 + 1U, in.width - 1U);
      const float wx = static_cast<float>(sx - static_cast<double>(x0));
      for (std::uint32_t c = 0; c < in.channels; ++c) {
        const float top = std::lerp(in.at(x0, y0, c), in.at(x1, y0, c), wx);
        const float bottom = std::lerp(in.at(x0, y1, c), in.at(x1, y1, c), wx);
        out.at(x, y, c) = std::lerp(top, bottom, wy);
      }
    }
  });
  return out;
}

FloatImage resample_to_max_edge(FloatImage source, std::uint32_t max_edge) {
  if (max_edge == 0) return source;
  if (max_edge > 8192) throw std::invalid_argument("preview max edge must be in [1,8192]");
  const auto longest = std::max(source.width, source.height);
  if (longest <= max_edge) return source;
  const double scale = static_cast<double>(max_edge) / static_cast<double>(longest);
  const auto width = std::max<std::uint32_t>(
      1, static_cast<std::uint32_t>(std::lround(source.width * scale)));
  const auto height = std::max<std::uint32_t>(
      1, static_cast<std::uint32_t>(std::lround(source.height * scale)));
  return resample_to(std::move(source), width, height);
}

}  // namespace hyperdr
