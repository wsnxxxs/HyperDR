#include "../src/internal/raw_geometry.hpp"
#include <iostream>
#include <stdexcept>

namespace {
void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}
void near(float value, float expected) {
  require(std::isfinite(value) && std::abs(value - expected) < 0.1F,
          "RAW float geometry changed the analytic field");
}
hyperdr::FloatImage field(unsigned width, unsigned height, unsigned channels) {
  hyperdr::FloatImage image(width, height, channels);
  for (unsigned y = 0; y < height; ++y)
    for (unsigned x = 0; x < width; ++x)
      for (unsigned c = 0; c < channels; ++c)
        image.at(x, y, c) = 70000.0F + 100 * y + 10 * x + c;
  return image;
}
}

int main() {
  try {
    for (unsigned channels : {3U, 4U}) {
      // Independently tabulated source pixel order for a 3x2 raster.
      constexpr unsigned order[8][6] = {{0,1,2,3,4,5}, {2,1,0,5,4,3},
          {3,4,5,0,1,2}, {5,4,3,2,1,0}, {0,3,1,4,2,5},
          {2,5,1,4,0,3}, {3,0,4,1,5,2}, {5,2,4,1,3,0}};
      for (int flip = 0; flip < 8; ++flip) {
        hyperdr::codec::RawOutputGeometry geometry;
        geometry.flip = flip;
        const auto out = hyperdr::codec::apply_raw_output_geometry(field(3, 2, channels), geometry);
        require(out.width == ((flip & 4) ? 2U : 3U) && out.height == ((flip & 4) ? 3U : 2U),
                "RAW flip dimensions changed");
        for (unsigned i = 0; i < 6; ++i)
          for (unsigned c = 0; c < channels; ++c)
            near(out.pixels[i * channels + c], 70000.0F + 100 * (order[flip][i] / 3) + 10 * (order[flip][i] % 3) + c);
      }
      for (double aspect : {0.5, 2.0}) {
        hyperdr::codec::RawOutputGeometry geometry;
        geometry.pixel_aspect = aspect;
        const auto out = hyperdr::codec::apply_raw_output_geometry(field(3, 2, channels), geometry);
        require(out.width == (aspect < 1 ? 3U : 6U) && out.height == (aspect < 1 ? 4U : 2U),
                "RAW aspect dimensions changed");
        for (unsigned y = 0; y < out.height; ++y)
          for (unsigned x = 0; x < out.width; ++x)
            for (unsigned c = 0; c < channels; ++c)
              near(out.at(x, y, c), static_cast<float>(70000.0 + 100 * std::min(1.0, aspect < 1 ? y * 0.5 : double(y))
                  + 10 * std::min(2.0, aspect > 1 ? x * 0.5 : double(x)) + c));
      }
      for (unsigned sample_step : {1U, 2U}) {
        hyperdr::codec::RawOutputGeometry geometry;
        geometry.fuji_width = 5;
        geometry.sample_step = sample_step;
        const auto out = hyperdr::codec::apply_raw_output_geometry(field(4, 8, channels), geometry);
        const unsigned f = sample_step == 1 ? 4 : 2;
        require(out.width == (sample_step == 1 ? 5U : 2U) && out.height == (sample_step == 1 ? 5U : 8U),
                "RAW Fuji dimensions changed");
        bool border_seen = false;
        for (unsigned y = 0; y < out.height; ++y)
          for (unsigned x = 0; x < out.width; ++x) {
            const double sy = f + (double(y) - x) * std::sqrt(0.5);
            const double sx = (double(y) + x) * std::sqrt(0.5);
            const bool border = sy < 0 || sx < 0 || sy >= 7 || sx >= 3;
            border_seen |= border;
            for (unsigned c = 0; c < channels; ++c)
              near(out.at(x, y, c), border ? 0.0F : static_cast<float>(70000 + 100 * sy + 10 * sx + c));
          }
        if (sample_step == 2) require(border_seen, "Fuji fixture did not exercise black borders");
      }
    }
    std::cout << "RAW float geometry passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
