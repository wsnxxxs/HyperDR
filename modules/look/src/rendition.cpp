#include "hyperdr/look/rendition.hpp"
#include "hyperdr/foundation/parallel.hpp"
namespace hyperdr {
void fit_sdr_to_srgb(FloatImage& image) {
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto i = (static_cast<std::size_t>(y) * image.width + x) * 3;
      const auto rgb = compress_linear_p3_to_srgb(
          image.pixels[i], image.pixels[i + 1], image.pixels[i + 2]);
      for (int c = 0; c < 3; ++c) image.pixels[i + c] = rgb[c];
    }
  });
}

}
