#include "hyperdr/look/filter.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <stdexcept>

namespace hyperdr {
namespace {

// Regularisation for the guided filter's per-cell linear fit. Large enough that
// a flat region does not amplify quantisation into visible blotches, small
// enough that a real highlight edge is still followed.
constexpr float kGuideEpsilon = 5.0e-3F;

}  // namespace

void box_mean(const std::vector<float>& input, std::vector<float>& output,
              std::uint32_t width, std::uint32_t height, std::uint32_t radius,
              std::vector<double>& integral) {
  const std::size_t count = static_cast<std::size_t>(width) * height;
  const std::size_t stride = static_cast<std::size_t>(width) + 1;
  if (input.size() != count || output.size() != count ||
      integral.size() != stride * (static_cast<std::size_t>(height) + 1)) {
    throw std::invalid_argument("invalid guided-filter buffer dimensions");
  }
  // Horizontal window sums, followed by vertical sliding windows. Keeping
  // nearby columns together avoids the full-height strided scan of a summed
  // area table. Double precision also avoids subtracting huge global totals.
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const auto row = static_cast<std::size_t>(y) * width;
    const auto value = [&](std::uint32_t x) {
      return static_cast<double>(clamp_finite(input[row + x], -64.0F, 64.0F));
    };
    double sum = 0.0;
    for (std::uint32_t x = 0; x < std::min(width, radius + 1U); ++x) sum += value(x);
    for (std::uint32_t x = 0; x < width; ++x) {
      integral[row + x] = sum;
      if (x >= radius) sum -= value(x - radius);
      if (x + radius + 1U < width) sum += value(x + radius + 1U);
    }
  });
  constexpr std::uint32_t tile_width = 16;
  parallel_for_rows((width + tile_width - 1U) / tile_width, [&](std::uint32_t tile) {
    const auto left = tile * tile_width;
    const auto columns = std::min(tile_width, width - left);
    std::array<double, tile_width> sums{};
    for (std::uint32_t y = 0; y < std::min(height, radius + 1U); ++y) {
      const auto row = static_cast<std::size_t>(y) * width + left;
      for (std::uint32_t c = 0; c < columns; ++c) sums[c] += integral[row + c];
    }
    for (std::uint32_t y = 0; y < height; ++y) {
      const auto y0 = y > radius ? y - radius : 0U;
      const auto y1 = std::min(height, y + radius + 1U);
      const auto row = static_cast<std::size_t>(y) * width + left;
      for (std::uint32_t c = 0; c < columns; ++c) {
        const auto x = left + c;
        const auto x0 = x > radius ? x - radius : 0U;
        const auto x1 = std::min(width, x + radius + 1U);
        output[row + c] = static_cast<float>(sums[c] / static_cast<double>((x1 - x0) * (y1 - y0)));
      }
      if (y >= radius) {
        const auto leaving = static_cast<std::size_t>(y - radius) * width + left;
        for (std::uint32_t c = 0; c < columns; ++c) sums[c] -= integral[leaving + c];
      }
      if (y + radius + 1U < height) {
        const auto entering = static_cast<std::size_t>(y + radius + 1U) * width + left;
        for (std::uint32_t c = 0; c < columns; ++c) sums[c] += integral[entering + c];
      }
    }
  });
}

namespace {

// Applies fn(i) to every element index across the width*height buffers,
// parallelized by row like box_mean's passes so this function does not drop
// back to single-threaded work between multi-threaded box_mean calls.
template <class Fn>
void for_each_pixel(std::uint32_t width, std::uint32_t height, Fn&& fn) {
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const std::size_t row = static_cast<std::size_t>(y) * width;
    for (std::uint32_t x = 0; x < width; ++x) fn(row + x);
  });
}

}  // namespace

void guided_filter_gain(std::vector<float>& gain, const std::vector<float>& global_gain,
                        const std::vector<float>& guide, std::uint32_t width,
                        std::uint32_t height, std::vector<float>& mean_i,
                        std::vector<float>& mean_p, std::vector<float>& work_one,
                        std::vector<float>& work_two, std::vector<double>& integral) {
  const std::uint32_t radius = std::clamp<std::uint32_t>(
      std::min(width, height) / 96U, 4U, 8U);
  box_mean(guide, mean_i, width, height, radius, integral);
  box_mean(gain, mean_p, width, height, radius, integral);

  for_each_pixel(width, height, [&](std::size_t i) { work_one[i] = guide[i] * guide[i]; });
  box_mean(work_one, work_two, width, height, radius, integral);  // E[I^2]
  for_each_pixel(width, height, [&](std::size_t i) { work_one[i] = guide[i] * gain[i]; });
  box_mean(work_one, gain, width, height, radius, integral);  // E[Ip]

  for_each_pixel(width, height, [&](std::size_t i) {
    const float variance = std::max(0.0F, work_two[i] - mean_i[i] * mean_i[i]);
    const float covariance = gain[i] - mean_i[i] * mean_p[i];
    work_two[i] = covariance / (variance + kGuideEpsilon);  // a
    gain[i] = mean_p[i] - work_two[i] * mean_i[i];           // b
  });
  box_mean(work_two, mean_p, width, height, radius, integral);  // E[a]
  box_mean(gain, mean_i, width, height, radius, integral);      // E[b]
  for_each_pixel(width, height, [&](std::size_t i) {
    const float filtered = mean_p[i] * guide[i] + mean_i[i];
    gain[i] = global_gain[i] <= 0.0F
                  ? 0.0F
                  : std::clamp(clamp_finite(filtered, 0.0F, global_gain[i]),
                               0.0F, global_gain[i]);
  });
}

}  // namespace hyperdr
