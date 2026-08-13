#pragma once

// The reduced-resolution grid the local gain is computed on, and the bilinear
// sampling that lifts it back to full resolution.
//
// The gain map is genuinely low frequency, so computing it per pixel would cost
// far more than it resolves; sharing one sampling rule between the grid builder
// and the full-resolution renderer is what stops the two from disagreeing about
// where a cell centre lies.

#include "hyperdr/image/image.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace hyperdr {

struct GainGridDimensions {
  std::uint32_t width{};
  std::uint32_t height{};
};

[[nodiscard]] GainGridDimensions choose_gain_dimensions(const FloatImage& source);

// The pixel coordinate where grid column/row `index` starts, for a grid of
// `divisions` cells spanning `extent` pixels.
//
// The product has to be computed in 64 bits. `index * extent` is a uint32 x
// uint32 multiply, and it wraps for large images: 2,864 x 1,500,000 exceeds
// UINT32_MAX, which collapsed that cell to a single pixel and rewound the
// following cell to near the top of the image. The result was not a memory
// error but a deterministically wrong gain grid -- the tail of the image never
// sampled, the head sampled twice -- which then propagated into scene
// statistics, exposure, headroom and the gain map. Both renderers that build a
// grid call this rather than keeping a copy of the fix.
[[nodiscard]] inline std::uint32_t grid_cell_edge(std::uint32_t index,
                                                  std::uint32_t extent,
                                                  std::uint32_t divisions) {
  if (divisions == 0) return 0;
  const auto edge = (static_cast<std::uint64_t>(index) * extent) / divisions;
  return static_cast<std::uint32_t>(
      edge < extent ? static_cast<std::uint32_t>(edge) : extent);
}

// Storage and dimensions, bound together and checked once.
//
// The sampler used to take a `vector` plus a width and height that nothing
// compared against it, so `sample_grid_bilinear({}, 1, 1, 1, 1, 0, 0)` read
// past the end of an empty vector: a documented public entry point with an
// unstated precondition. Constructing the view is the only way to name a grid,
// and the constructor is where the precondition is enforced, so the per-pixel
// sampling loop stays free of repeated checks.
class GridView {
 public:
  GridView(const float* data, std::size_t size, std::uint32_t width,
           std::uint32_t height);
  GridView(const std::vector<float>& grid, std::uint32_t width,
           std::uint32_t height)
      : GridView(grid.data(), grid.size(), width, height) {}

  [[nodiscard]] std::uint32_t width() const { return width_; }
  [[nodiscard]] std::uint32_t height() const { return height_; }
  // `x` and `y` must already be inside the grid; `bilinear_grid_coordinates`
  // is the only producer of them and clamps to `width - 1` / `height - 1`.
  [[nodiscard]] float at(std::uint32_t x, std::uint32_t y) const {
    return data_[static_cast<std::size_t>(y) * width_ + x];
  }

 private:
  const float* data_{};
  std::uint32_t width_{};
  std::uint32_t height_{};
};

struct BilinearGridCoordinates {
  std::uint32_t x0{};
  std::uint32_t x1{};
  std::uint32_t y0{};
  std::uint32_t y1{};
  float tx{};
  float ty{};
};

// Throws for a zero grid or image extent rather than dividing by zero and
// clamping a NaN, whose conversion to an unsigned index is undefined.
[[nodiscard]] BilinearGridCoordinates bilinear_grid_coordinates(
    std::uint32_t grid_width, std::uint32_t grid_height,
    std::uint32_t image_width, std::uint32_t image_height, std::uint32_t x,
    std::uint32_t y);

[[nodiscard]] float sample_grid_bilinear(const GridView& grid,
                                         std::uint32_t image_width,
                                         std::uint32_t image_height,
                                         std::uint32_t x, std::uint32_t y);

// Convenience overload. It validates the buffer against the dimensions on
// every call, which is a handful of integer comparisons against four lerps.
[[nodiscard]] float sample_grid_bilinear(const std::vector<float>& grid,
                                         std::uint32_t grid_width,
                                         std::uint32_t grid_height,
                                         std::uint32_t image_width,
                                         std::uint32_t image_height,
                                         std::uint32_t x, std::uint32_t y);

}  // namespace hyperdr
