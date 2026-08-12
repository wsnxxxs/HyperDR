// The conversion preview and the thumbnail command used to resample by
// different rules. The preview halved while the longest edge exceeded the
// bound, so a request for 1600 px could land on 800 px. These cases pin the
// shared policy: the longest edge lands exactly on the bound, aspect ratio is
// preserved, and averaging happens in linear light.

#include "hyperdr/image/resample.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::FloatImage constant_image(std::uint32_t width, std::uint32_t height, float value) {
  hyperdr::FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      for (std::uint32_t c = 0; c < 3; ++c) image.at(x, y, c) = value;
    }
  }
  return image;
}

void check_exact_bound() {
  // 3201 is the case that previously overshot: one halving gives 1601, which
  // still exceeds 1600, so the old loop halved again to 801.
  const auto reduced = hyperdr::resample_to_max_edge(constant_image(3201, 2134, 0.5F), 1600);
  require(std::max(reduced.width, reduced.height) == 1600,
          "the longest edge must land exactly on the bound");
  const double source_ratio = 3201.0 / 2134.0;
  const double result_ratio = static_cast<double>(reduced.width) / reduced.height;
  require(std::abs(source_ratio - result_ratio) < 0.005, "aspect ratio must be preserved");
}

void check_no_upscale_and_passthrough() {
  const auto small = hyperdr::resample_to_max_edge(constant_image(100, 60, 0.25F), 1600);
  require(small.width == 100 && small.height == 60,
          "an image already within the bound must be returned unchanged");
  const auto unbounded = hyperdr::resample_to_max_edge(constant_image(100, 60, 0.25F), 0);
  require(unbounded.width == 100 && unbounded.height == 60,
          "a bound of zero must disable resampling");
}

// A flat field must survive both the halving chain and the bilinear step
// exactly; any leak of an OETF into this path would shift the value.
void check_linear_light_is_preserved() {
  const auto reduced = hyperdr::resample_to_max_edge(constant_image(2000, 1000, 0.375F), 137);
  for (std::uint32_t y = 0; y < reduced.height; ++y) {
    for (std::uint32_t x = 0; x < reduced.width; ++x) {
      for (std::uint32_t c = 0; c < 3; ++c) {
        require(std::abs(reduced.at(x, y, c) - 0.375F) < 1.0e-5F,
                "a constant field must resample to the same constant");
      }
    }
  }
}

// A single bright pixel carries energy that must not vanish: box averaging
// spreads it, so the mean over the reduced image tracks the mean of the source.
void check_energy_is_not_lost() {
  hyperdr::FloatImage image = constant_image(512, 512, 0.0F);
  for (std::uint32_t y = 200; y < 300; ++y) {
    for (std::uint32_t x = 200; x < 300; ++x) image.at(x, y, 0) = 4.0F;
  }
  double source_sum = 0.0;
  for (std::uint32_t y = 0; y < 512; ++y) {
    for (std::uint32_t x = 0; x < 512; ++x) source_sum += image.at(x, y, 0);
  }
  const auto reduced = hyperdr::resample_to_max_edge(std::move(image), 64);
  double reduced_sum = 0.0;
  for (std::uint32_t y = 0; y < reduced.height; ++y) {
    for (std::uint32_t x = 0; x < reduced.width; ++x) reduced_sum += reduced.at(x, y, 0);
  }
  const double scale = (512.0 * 512.0) / (static_cast<double>(reduced.width) * reduced.height);
  require(std::abs(reduced_sum * scale - source_sum) / source_sum < 0.02,
          "resampling must approximately preserve total energy");
}

void check_single_axis_downscale_is_antialiased() {
  hyperdr::FloatImage horizontal(16, 1, 1);
  for (std::uint32_t x = 0; x < horizontal.width; ++x) {
    horizontal.at(x, 0, 0) = static_cast<float>(x % 2U);
  }
  const auto horizontal_reduced =
      hyperdr::resample_to(std::move(horizontal), 5, 1);
  for (std::uint32_t x = 0; x < horizontal_reduced.width; ++x) {
    require(std::abs(horizontal_reduced.at(x, 0, 0) - 0.5F) < 1.0e-6F,
            "horizontal-only downscale must low-pass high frequencies");
  }

  hyperdr::FloatImage vertical(1, 16, 1);
  for (std::uint32_t y = 0; y < vertical.height; ++y) {
    vertical.at(0, y, 0) = static_cast<float>(y % 2U);
  }
  const auto vertical_reduced = hyperdr::resample_to(std::move(vertical), 1, 5);
  for (std::uint32_t y = 0; y < vertical_reduced.height; ++y) {
    require(std::abs(vertical_reduced.at(0, y, 0) - 0.5F) < 1.0e-6F,
            "vertical-only downscale must low-pass high frequencies");
  }
}

void check_exact_size() {
  const auto exact = hyperdr::resample_to(constant_image(1000, 500, 1.0F), 333, 111);
  require(exact.width == 333 && exact.height == 111, "resample_to must honour its size");
  bool threw = false;
  try {
    static_cast<void>(hyperdr::resample_to(constant_image(10, 10, 1.0F), 0, 5));
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "a zero target must be rejected");
  threw = false;
  try {
    static_cast<void>(hyperdr::resample_to_max_edge(constant_image(10, 10, 1.0F), 9000));
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "a bound above 8192 must be rejected");
}

void check_large_coordinate_precision() {
  hyperdr::FloatImage image(16'777'220, 1, 1);
  image.at(image.width - 1U, 0, 0) = 1.0F;
  const auto reduced = hyperdr::resample_to(std::move(image), 16'777'217, 1);
  require(reduced.width == 16'777'217 && std::isfinite(reduced.at(reduced.width - 1U, 0, 0)),
          "large bilinear coordinates must stay inside the source image");
}

void check_size_overflow_is_rejected() {
  bool threw = false;
  try {
    static_cast<void>(hyperdr::FloatImage::checked_size(1U << 31, 1U << 31, 4));
  } catch (const std::length_error&) {
    threw = true;
  }
  require(threw, "overflowing image dimensions must be rejected");
}

}  // namespace

int main() {
  try {
    check_exact_bound();
    check_no_upscale_and_passthrough();
    check_linear_light_is_preserved();
    check_energy_is_not_lost();
    check_single_axis_downscale_is_antialiased();
    check_exact_size();
    check_large_coordinate_precision();
    check_size_overflow_is_rejected();
  } catch (const std::exception& e) {
    std::cerr << "resample_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "resample_test passed\n";
  return 0;
}
