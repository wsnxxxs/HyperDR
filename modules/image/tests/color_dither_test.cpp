#include "hyperdr/image/color.hpp"

#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
}  // namespace

int main() {
  try {
    using namespace hyperdr;

    // D65 white in XYZ maps to a neutral (equal-channel) Display P3 colour.
    const auto white = xyz_d65_to_linear_p3(0.95047F, 1.0F, 1.08883F);
    require(std::abs(white[0] - white[1]) < 2.0e-3F &&
                std::abs(white[1] - white[2]) < 2.0e-3F,
            "D65 white did not map to a neutral P3 colour");
    // Display P3 primaries round-trip through their standard D65 XYZ values.
    const auto red = xyz_d65_to_linear_p3(0.48657095F, 0.22897456F, 0.0F);
    const auto green = xyz_d65_to_linear_p3(0.26566769F, 0.69173852F, 0.04511338F);
    const auto blue = xyz_d65_to_linear_p3(0.19821729F, 0.07928691F, 1.04394437F);
    require(red[0] > 0.999F && red[1] < 0.001F && red[2] < 0.001F &&
                green[0] < 0.001F && green[1] > 0.999F && green[2] < 0.001F &&
                blue[0] < 0.001F && blue[1] < 0.001F && blue[2] > 0.999F,
            "XYZ to Display P3 primary conversion is inaccurate");

    // ProPhoto's equal-channel white must remain neutral and exactly preserve
    // its level. This is the property that avoids XYZ's 16-bit Z-channel clip
    // in the LibRaw path.
    const auto prophoto_white = prophoto_to_linear_p3(1.0F, 1.0F, 1.0F);
    require(std::abs(prophoto_white[0] - 1.0F) < 1.0e-5F &&
                std::abs(prophoto_white[1] - 1.0F) < 1.0e-5F &&
                std::abs(prophoto_white[2] - 1.0F) < 1.0e-5F,
            "ProPhoto white did not map to neutral unit P3");

    // Wide-gamut detection: a saturated P3 green is outside Rec.709; neutral and
    // moderately saturated in-gamut colours are not.
    require(is_outside_rec709(0.0F, 0.6F, 0.0F),
            "saturated P3 green not flagged outside Rec.709");
    require(!is_outside_rec709(0.4F, 0.4F, 0.4F),
            "neutral grey wrongly flagged outside Rec.709");
    require(!is_outside_rec709(0.5F, 0.2F, 0.1F),
            "in-gamut warm colour wrongly flagged outside Rec.709");

    const auto green2020 = rec2020_to_linear_p3(0.0F, 1.0F, 0.0F);
    require(green2020[1] > 0.0F, "Rec.2020 green lost luminance converting to P3");

    // Dither must be deterministic and stay in range.
    require(quantize_dithered(0.321F, 255, 5, 9, 1) ==
                quantize_dithered(0.321F, 255, 5, 9, 1),
            "dithered quantization is not deterministic");
    for (int i = 0; i < 2000; ++i) {
      const int q = quantize_dithered(static_cast<float>(i) / 1999.0F, 255,
                                      static_cast<std::uint32_t>(i),
                                      static_cast<std::uint32_t>(2 * i),
                                      static_cast<std::uint32_t>(i % 3));
      require(q >= 0 && q <= 255, "dithered code left [0, max]");
    }

    // TPDF dither has zero mean, so the average code tracks the undithered value.
    for (const float v : {0.0F, 0.25F, 0.5F, 0.753F, 1.0F}) {
      double sum = 0.0;
      int count = 0;
      for (std::uint32_t y = 0; y < 128; ++y) {
        for (std::uint32_t x = 0; x < 128; ++x) {
          sum += quantize_dithered(v, 1023, x, y, 0);
          ++count;
        }
      }
      const double mean = sum / count;
      require(std::abs(mean - static_cast<double>(v) * 1023.0) < 2.0,
              "dither mean drifted from the undithered value");
    }

    std::cout << "color/dither tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "color/dither test failure: " << error.what() << '\n';
    return 1;
  }
}
