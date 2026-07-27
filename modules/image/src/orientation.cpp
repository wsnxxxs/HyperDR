#include "hyperdr/image/orientation.hpp"

#include "hyperdr/foundation/parallel.hpp"

#include <cstddef>
#include <cstdint>
#include <utility>

namespace hyperdr {

bool exif_orientation_transposes(const std::uint16_t orientation) {
  return orientation >= 5 && orientation <= 8;
}

FloatImage apply_exif_orientation(FloatImage image,
                                  const std::uint16_t orientation) {
  if (orientation <= 1 || orientation > 8) return image;
  image.require_consistent("image to reorient");

  const std::uint32_t width = image.width;
  const std::uint32_t height = image.height;
  const std::uint32_t channels = image.channels;
  const bool transposed = exif_orientation_transposes(orientation);
  FloatImage out(transposed ? height : width, transposed ? width : height,
                 channels);

  // Source coordinate for a destination coordinate, per Exif orientation.
  // Written as an explicit mapping rather than a composition of flips so that
  // each of the eight cases is readable against the specification table.
  parallel_for_rows(out.height, [&](const std::uint32_t y) {
    for (std::uint32_t x = 0; x < out.width; ++x) {
      std::uint32_t sx = x;
      std::uint32_t sy = y;
      switch (orientation) {
        case 2: sx = width - 1 - x; sy = y; break;                 // mirror H
        case 3: sx = width - 1 - x; sy = height - 1 - y; break;    // rotate 180
        case 4: sx = x;             sy = height - 1 - y; break;    // mirror V
        case 5: sx = y;             sy = x; break;                 // transpose
        case 6: sx = y;             sy = height - 1 - x; break;    // rotate 90 CW
        case 7: sx = width - 1 - y; sy = height - 1 - x; break;    // transverse
        case 8: sx = width - 1 - y; sy = x; break;                 // rotate 270 CW
        default: break;
      }
      const auto source = (static_cast<std::size_t>(sy) * width + sx) * channels;
      const auto target =
          (static_cast<std::size_t>(y) * out.width + x) * channels;
      for (std::uint32_t c = 0; c < channels; ++c) {
        out.pixels[target + c] = image.pixels[source + c];
      }
    }
  });
  return out;
}

}  // namespace hyperdr
