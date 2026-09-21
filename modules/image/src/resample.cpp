#include "hyperdr/image/resample.hpp"

#include "hyperdr/foundation/parallel.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

// Each shrinking output pixel covers an equal area of the input raster.
// Enlarged axes keep centre-aligned linear interpolation.
struct Footprint {
  std::uint32_t first, last;
  float first_weight, last_weight;
};
Footprint footprint(std::uint32_t position, std::uint32_t input, std::uint32_t output) {
  const double scale = static_cast<double>(input) / output;
  if (input > output) {
    const double left = position * scale;
    const double right = std::min(static_cast<double>(input), (position + 1.0) * scale);
    const auto first = static_cast<std::uint32_t>(std::floor(left));
    const auto last = std::min(input - 1U, static_cast<std::uint32_t>(std::ceil(right) - 1));
    return {first, last, static_cast<float>((std::min(right, first + 1.0) - left) / scale),
            static_cast<float>((right - std::max(left, static_cast<double>(last))) / scale)};
  }
  const double coordinate = std::clamp((position + 0.5) * scale - 0.5, 0.0, input - 1.0);
  const auto first = static_cast<std::uint32_t>(std::floor(coordinate));
  const auto last = std::min(first + 1U, input - 1U);
  const float weight = static_cast<float>(coordinate - first);
  return {first, last, first == last ? 1.0F : 1.0F - weight, weight};
}
float weight_at(const Footprint& span, std::uint32_t index, float interior) {
  return index == span.first ? span.first_weight : index == span.last ? span.last_weight : interior;
}
FloatImage resample_stage(const FloatImage& source, std::uint32_t width, std::uint32_t height) {
  FloatImage out(width, height, source.channels);
  std::vector<Footprint> columns(width);
  for (std::uint32_t x = 0; x < width; ++x) columns[x] = footprint(x, source.width, width);
  const float interior_x = static_cast<float>(static_cast<double>(width) / source.width);
  const float interior_y = static_cast<float>(static_cast<double>(height) / source.height);
  parallel_for_rows(height, [&](std::uint32_t y) {
    const auto rows = footprint(y, source.height, height);
    for (std::uint32_t x = 0; x < width; ++x) {
      const auto& cols = columns[x];
      for (std::uint32_t c = 0; c < source.channels; ++c) {
        double sum = 0;
        for (auto sy = rows.first; sy <= rows.last; ++sy) {
          const float wy = weight_at(rows, sy, interior_y);
          if (wy == 0) continue;
          double row = 0;
          for (auto sx = cols.first; sx <= cols.last; ++sx) {
            const float wx = weight_at(cols, sx, interior_x);
            if (wx != 0) row += source.at(sx, sy, c) * static_cast<double>(wx);
          }
          sum += row * wy;
        }
        out.at(x, y, c) = static_cast<float>(sum);
      }
    }
  });
  return out;
}

FloatImage halve(const FloatImage& source, bool reduce_width,
                 bool reduce_height) {
  // Pair averaging is exact only when every output cell has the same area.
  // An odd tail must not receive a full output pixel's weight by itself.
  if ((reduce_width && source.width % 2U) || (reduce_height && source.height % 2U))
    return resample_stage(source, reduce_width ? (source.width / 2U + source.width % 2U) : source.width,
        reduce_height ? (source.height / 2U + source.height % 2U) : source.height);
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

  // Staged low-pass filtering bounds the final footprint and suppresses fine
  // alternating texture. Each stage preserves equal-area pixel coverage.
  while (true) {
    // Compare in 64 bits. Integer division made 3201 -> 1600 look like an
    // exact 2:1 step and skipped the box filter even though it undersamples.
    const bool reduce_width = source.width > 1U &&
        static_cast<std::uint64_t>(source.width) >
            static_cast<std::uint64_t>(width) * 2U;
    const bool reduce_height = source.height > 1U &&
        static_cast<std::uint64_t>(source.height) >
            static_cast<std::uint64_t>(height) * 2U;
    if (!reduce_width && !reduce_height) break;
    source = halve(source, reduce_width, reduce_height);
  }
  if (source.width == width && source.height == height) return source;

  return resample_stage(source, width, height);
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
