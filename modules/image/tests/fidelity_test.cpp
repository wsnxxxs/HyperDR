#include "hyperdr/image/fidelity.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::FloatImage gradient(std::uint32_t width, std::uint32_t height, float peak) {
  hyperdr::FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const float value = peak * static_cast<float>(x + 1) / static_cast<float>(width);
      image.at(x, y, 0) = value;
      image.at(x, y, 1) = value * (0.6F + 0.4F * static_cast<float>(y) / height);
      image.at(x, y, 2) = value * 0.8F;
    }
  }
  return image;
}

void test_identical_images_have_no_error() {
  const auto image = gradient(97, 71, 4.9F);
  const auto result = hyperdr::measure_hdr_fidelity(image, image);
  require(result.pixels == 97U * 71U, "every pixel is compared");
  require(result.delta_e_itp_mean == 0.0 && result.delta_e_itp_max == 0.0F,
          "identical images have zero delta E ITP");
  require(std::isinf(result.psnr_pq_db), "identical images have infinite PSNR");
  require(result.reference_peak == result.candidate_peak, "peaks agree");
  require(result.reference_peak > 4.5F && result.reference_peak < 4.9F,
          "the reference peak is the brightest luminance");
}

// A uniform one-percent luminance change sits near one JND for mid-grey at
// 203 cd/m² white; the metric has to see it without calling it large.
void test_small_luminance_change_is_near_one_jnd() {
  const auto reference = gradient(64, 64, 1.0F);
  auto candidate = reference;
  for (auto& value : candidate.pixels) value *= 1.01F;
  const auto result = hyperdr::measure_hdr_fidelity(reference, candidate);
  require(result.delta_e_itp_mean > 0.3 && result.delta_e_itp_mean < 3.0,
          "a 1% luminance change is around one JND");
  require(result.delta_e_itp_p99 >= result.delta_e_itp_p50, "percentiles are ordered");
  require(result.delta_e_itp_max >= result.delta_e_itp_p999, "max bounds the percentiles");
  require(result.psnr_pq_db > 40.0 && std::isfinite(result.psnr_pq_db),
          "PSNR is finite and high for a 1% change");
}

// Losing the highlight range is what a gain-map conversion must not do, and a
// mean over mostly dark pixels could hide it. The highlight band must not.
void test_clipped_highlights_are_visible_in_their_band() {
  hyperdr::FloatImage reference(100, 10, 3);
  for (std::uint32_t y = 0; y < 10; ++y) {
    for (std::uint32_t x = 0; x < 100; ++x) {
      const float value = x < 90 ? 0.05F : 4.0F;
      for (unsigned c = 0; c < 3; ++c) reference.at(x, y, c) = value;
    }
  }
  auto candidate = reference;
  for (auto& value : candidate.pixels) value = std::min(value, 1.0F);
  const auto result = hyperdr::measure_hdr_fidelity(reference, candidate);
  require(result.band_pixels[0] == 900U && result.band_pixels[2] == 100U,
          "pixels are banded by reference luminance");
  require(result.band_delta_e_itp_mean[0] == 0.0, "untouched shadows have no error");
  require(result.band_delta_e_itp_mean[2] > 50.0, "two lost stops are a large error");
  require(std::abs(result.candidate_peak - 1.0F) < 1.0e-4F &&
              std::abs(result.reference_peak - 4.0F) < 1.0e-3F,
          "the lost peak is reported");
}

void test_dimension_mismatch_is_rejected() {
  bool threw = false;
  try {
    (void)hyperdr::measure_hdr_fidelity(gradient(8, 8, 1.0F), gradient(8, 9, 1.0F));
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "images of different sizes cannot be compared");
}

}  // namespace

int main() {
  try {
    test_identical_images_have_no_error();
    test_small_luminance_change_is_near_one_jnd();
    test_clipped_highlights_are_visible_in_their_band();
    test_dimension_mismatch_is_rejected();
  } catch (const std::exception& error) {
    std::cerr << "fidelity_test failed: " << error.what() << '\n';
    return 1;
  }
  std::cout << "fidelity_test passed\n";
  return 0;
}
