#include "hyperdr/look/filter.hpp"

#include <cmath>
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

int main() {
  try {
    // A direct local sum checks cropped windows, signs, and tile boundaries.
    for (const auto width : {1U, 17U, 67U}) {
      constexpr unsigned height = 19;
      std::vector<float> input(width * height), output(input.size());
      std::vector<double> scratch((width + 1) * (height + 1));
      for (std::size_t i = 0; i < input.size(); ++i)
        input[i] = static_cast<float>(static_cast<int>((i * 37) % 509) - 254) * 0.3F;
      for (const auto radius : {0U, 4U, 64U}) {
        hyperdr::box_mean(input, output, width, height, radius, scratch);
        for (unsigned y = 0; y < height; ++y) for (unsigned x = 0; x < width; ++x) {
          double sum = 0; unsigned samples = 0;
          for (auto yy = y > radius ? y - radius : 0U; yy < std::min(height, y + radius + 1); ++yy)
            for (auto xx = x > radius ? x - radius : 0U; xx < std::min(width, x + radius + 1); ++xx) {
              sum += std::clamp(input[yy * width + xx], -64.0F, 64.0F); ++samples;
            }
          if (std::abs(output[y * width + x] - sum / samples) > 1.0e-5)
            throw std::runtime_error("sliding window differs from direct local mean");
        }
      }
    }
    constexpr std::uint32_t width = 1024;
    constexpr std::uint32_t height = 1024;
    constexpr float value = 63.75F;
    const std::size_t count = static_cast<std::size_t>(width) * height;
    std::vector<float> input(count, value);
    std::vector<float> output(count, 0.0F);
    std::vector<double> integral(static_cast<std::size_t>(width + 1) * (height + 1), 0.0);
    hyperdr::box_mean(input, output, width, height, 64, integral);
    for (const float mean : output) {
      if (std::abs(mean - value) > 1.0e-5F) {
        throw std::runtime_error("large-grid constant mean lost precision");
      }
    }
    std::cout << "guided-filter precision tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "guided-filter precision test failure: " << error.what() << '\n';
    return 1;
  }
}
