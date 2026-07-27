#include "hyperdr/look/filter.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"

#include <algorithm>
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
  std::fill(integral.begin(), integral.begin() + static_cast<std::ptrdiff_t>(stride), 0.0);
  // Build the summed-area table in two independent passes. Double precision is
  // required here: a 3072-square grid can accumulate billions before four
  // nearby table entries are subtracted to recover a small local window.
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const std::size_t row = static_cast<std::size_t>(y) * width;
    const std::size_t integral_row = static_cast<std::size_t>(y + 1) * stride;
    integral[integral_row] = 0.0;
    double running = 0.0;
    for (std::uint32_t x = 0; x < width; ++x) {
      running += static_cast<double>(clamp_finite(input[row + x], -64.0F, 64.0F));
      integral[integral_row + x + 1] = running;
    }
  });
  parallel_for_rows(width, [&](const std::uint32_t x) {
    const std::size_t column = static_cast<std::size_t>(x) + 1;
    for (std::uint32_t y = 1; y <= height; ++y) {
      integral[static_cast<std::size_t>(y) * stride + column] +=
          integral[static_cast<std::size_t>(y - 1) * stride + column];
    }
  });
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const std::uint32_t y0 = y > radius ? y - radius : 0;
    const std::uint32_t y1 = std::min(height, y + radius + 1U);
    for (std::uint32_t x = 0; x < width; ++x) {
      const std::uint32_t x0 = x > radius ? x - radius : 0;
      const std::uint32_t x1 = std::min(width, x + radius + 1U);
      const double sum = integral[static_cast<std::size_t>(y1) * stride + x1] -
                         integral[static_cast<std::size_t>(y0) * stride + x1] -
                         integral[static_cast<std::size_t>(y1) * stride + x0] +
                         integral[static_cast<std::size_t>(y0) * stride + x0];
      output[static_cast<std::size_t>(y) * width + x] =
          static_cast<float>(sum / static_cast<double>((x1 - x0) * (y1 - y0)));
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
