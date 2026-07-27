#include "hyperdr/look/filter.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

int main() {
  try {
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
