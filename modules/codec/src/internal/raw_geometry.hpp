#pragma once

#include "budget.hpp"
#include "hyperdr/image/orientation.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <utility>

namespace hyperdr::codec {

struct RawOutputGeometry {
  unsigned fuji_width{}, sample_step{1};
  double pixel_aspect{1};
  int flip{};
};

inline FloatImage apply_raw_output_geometry(FloatImage image, const RawOutputGeometry& geometry) {
  image.require_consistent("RAW camera geometry");
  const auto dimension = [](double value) {
    if (!std::isfinite(value) || value < 1 || value > std::numeric_limits<unsigned>::max())
      throw std::runtime_error("invalid RAW output dimension");
    return static_cast<unsigned>(value);
  };
  const auto allocate = [&](unsigned width, unsigned height) {
    if (!raw_input_budget_ok(width, height))
      throw std::runtime_error("RAW output geometry exceeds pixel budget");
    return FloatImage(width, height, image.channels);
  };
  if (!raw_input_budget_ok(image.width, image.height))
    throw std::runtime_error("RAW input geometry exceeds pixel budget");
  if (geometry.fuji_width) {
    if (geometry.sample_step != 1 && geometry.sample_step != 2)
      throw std::runtime_error("invalid RAW geometry sample step");
    const unsigned shrink = geometry.sample_step == 2 ? 1 : 0;
    const unsigned f = (geometry.fuji_width - 1 + shrink) >> shrink;
    const double step = std::sqrt(0.5);
    auto out = allocate(dimension(f / step), dimension((static_cast<double>(image.height) - f) / step));
    for (unsigned y = 0; y < out.height; ++y)
      for (unsigned x = 0; x < out.width; ++x) {
        // Match LibRaw's float source coordinates and complete-neighbour border.
        const float sy = static_cast<float>(f + (static_cast<double>(y) - x) * step);
        const float sx = static_cast<float>((static_cast<double>(y) + x) * step);
        if (sx < 0 || sy < 0 || image.width < 2 || image.height < 2) continue;
        const unsigned iy = static_cast<unsigned>(sy), ix = static_cast<unsigned>(sx);
        if (iy > image.height - 2 || ix > image.width - 2) continue;
        const float fy = sy - iy, fx = sx - ix;
        for (unsigned c = 0; c < image.channels; ++c)
          out.at(x, y, c) = (image.at(ix, iy, c) * (1 - fx) + image.at(ix + 1, iy, c) * fx) * (1 - fy)
              + (image.at(ix, iy + 1, c) * (1 - fx) + image.at(ix + 1, iy + 1, c) * fx) * fy;
      }
    image = std::move(out);
  }
  const double aspect = geometry.pixel_aspect;
  if (!std::isfinite(aspect) || aspect <= 0)
    throw std::runtime_error("invalid RAW pixel aspect ratio");
  if (aspect != 1) {
    const bool vertical = aspect < 1;
    auto out = allocate(vertical ? image.width : dimension(image.width * aspect + 0.5),
                        vertical ? dimension(image.height / aspect + 0.5) : image.height);
    const unsigned count = vertical ? out.height : out.width;
    const unsigned source_count = vertical ? image.height : image.width;
    const double step = vertical ? aspect : 1 / aspect;
    double coordinate = 0;
    for (unsigned i = 0; i < count; ++i, coordinate += step) {
      const double position = std::min(coordinate, static_cast<double>(source_count - 1));
      const unsigned a = static_cast<unsigned>(position), b = std::min(a + 1, source_count - 1);
      // Deliberately retain the fraction discarded by LibRaw's int conversion.
      const float fraction = static_cast<float>(position - a);
      for (unsigned j = 0; j < (vertical ? out.width : out.height); ++j)
        for (unsigned c = 0; c < image.channels; ++c)
          out.at(vertical ? j : i, vertical ? i : j, c) =
              image.at(vertical ? j : a, vertical ? a : j, c) * (1 - fraction)
              + image.at(vertical ? j : b, vertical ? b : j, c) * fraction;
    }
    image = std::move(out);
  }
  constexpr std::uint16_t orientations[]{1, 2, 4, 3, 5, 8, 6, 7};
  return apply_exif_orientation(std::move(image), orientations[static_cast<unsigned>(geometry.flip) & 7U]);
}

}  // namespace hyperdr::codec
