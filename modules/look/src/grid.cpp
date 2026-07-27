#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

// A gain grid finer than this buys nothing: the map is low frequency by
// construction, and the guided filter's window is measured in cells.
constexpr std::uint32_t kMaxGainGridEdge = 3072;

std::uint32_t ceil_divide(std::uint32_t numerator, std::uint32_t denominator) {
  return (numerator + denominator - 1U) / denominator;
}

}  // namespace

GridView::GridView(const float* data, std::size_t size, std::uint32_t width,
                   std::uint32_t height)
    : data_(data), width_(width), height_(height) {
  if (width == 0 || height == 0) {
    throw std::invalid_argument("grid dimensions must be non-zero");
  }
  const auto required =
      static_cast<std::uint64_t>(width) * static_cast<std::uint64_t>(height);
  if (data == nullptr || static_cast<std::uint64_t>(size) < required) {
    throw std::invalid_argument("grid buffer is smaller than its dimensions");
  }
}

GainGridDimensions choose_gain_dimensions(const FloatImage& source) {
  const std::uint32_t scale = std::max(
      {2U, ceil_divide(source.width, kMaxGainGridEdge),
       ceil_divide(source.height, kMaxGainGridEdge)});
  return {ceil_divide(source.width, scale),
          ceil_divide(source.height, scale)};
}

BilinearGridCoordinates bilinear_grid_coordinates(
    std::uint32_t grid_width, std::uint32_t grid_height,
    std::uint32_t image_width, std::uint32_t image_height, std::uint32_t x,
    std::uint32_t y) {
  if (grid_width == 0 || grid_height == 0 || image_width == 0 ||
      image_height == 0) {
    throw std::invalid_argument("grid and image extents must be non-zero");
  }
  // Double, not float: `(x + 0.5) * grid_width` reaches 4.6e9 for a 1.5e6-wide
  // image, well past a float's 24-bit mantissa, and the rounding error lands
  // directly on the cell index the caller then floors.
  const double gx =
      std::clamp((static_cast<double>(x) + 0.5) *
                         static_cast<double>(grid_width) /
                         static_cast<double>(image_width) -
                     0.5,
                 0.0, static_cast<double>(grid_width - 1U));
  const double gy =
      std::clamp((static_cast<double>(y) + 0.5) *
                         static_cast<double>(grid_height) /
                         static_cast<double>(image_height) -
                     0.5,
                 0.0, static_cast<double>(grid_height - 1U));
  // The clamp bounds both values by `extent - 1`, and the explicit min keeps
  // the index inside the grid even if the floor lands exactly on the bound.
  const auto x0 =
      std::min(static_cast<std::uint32_t>(std::floor(gx)), grid_width - 1U);
  const auto y0 =
      std::min(static_cast<std::uint32_t>(std::floor(gy)), grid_height - 1U);
  return {x0,
          std::min(x0 + 1U, grid_width - 1U),
          y0,
          std::min(y0 + 1U, grid_height - 1U),
          static_cast<float>(gx - x0),
          static_cast<float>(gy - y0)};
}

float sample_grid_bilinear(const GridView& grid, std::uint32_t image_width,
                           std::uint32_t image_height, std::uint32_t x,
                           std::uint32_t y) {
  const auto c = bilinear_grid_coordinates(grid.width(), grid.height(),
                                           image_width, image_height, x, y);
  const float top = std::lerp(grid.at(c.x0, c.y0), grid.at(c.x1, c.y0), c.tx);
  const float bottom =
      std::lerp(grid.at(c.x0, c.y1), grid.at(c.x1, c.y1), c.tx);
  return std::lerp(top, bottom, c.ty);
}

float sample_grid_bilinear(const std::vector<float>& grid,
                           std::uint32_t grid_width, std::uint32_t grid_height,
                           std::uint32_t image_width,
                           std::uint32_t image_height, std::uint32_t x,
                           std::uint32_t y) {
  return sample_grid_bilinear(GridView(grid, grid_width, grid_height),
                              image_width, image_height, x, y);
}

}  // namespace hyperdr
