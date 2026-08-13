#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <utility>

namespace {

void require_close(float actual, float expected, float tolerance,
                   const char* message) {
  if (std::abs(actual - expected) > tolerance) {
    throw std::runtime_error(message);
  }
}

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::FloatImage base_image(float value) {
  hyperdr::FloatImage base(1, 1, 3);
  for (float& sample : base.pixels) sample = value;
  return base;
}

hyperdr::FloatImage gain_image(float code) {
  hyperdr::FloatImage gain(1, 1, 1);
  gain.pixels[0] = code;
  return gain;
}

hyperdr::GainMapMetadata positive_metadata() {
  hyperdr::GainMapMetadata metadata;
  metadata.gain_min = {0, 1};
  metadata.gain_max = {2, 1};
  metadata.gamma = {1, 1};
  metadata.base_offset = {0, 1};
  metadata.alternate_offset = {0, 1};
  metadata.base_headroom = {0, 1};
  metadata.alternate_headroom = {2, 1};
  return metadata;
}

void test_physical_headroom_weight() {
  const auto base = base_image(1.0F);
  const auto gain = gain_image(0.5F);
  const auto metadata = positive_metadata();

  const auto at_base = hyperdr::reconstruct_gain_map(base, gain, metadata, 0.0F);
  const auto below_base =
      hyperdr::reconstruct_gain_map(base, gain, metadata, -1.0F);
  const auto at_alt = hyperdr::reconstruct_gain_map(base, gain, metadata, 2.0F);
  const auto above_alt =
      hyperdr::reconstruct_gain_map(base, gain, metadata, 3.0F);
  require_close(at_base.pixels[0], 1.0F, 1.0e-6F,
                "base-headroom endpoint did not produce w=0");
  require_close(below_base.pixels[0], 1.0F, 1.0e-6F,
                "headroom below base did not clamp to w=0");
  require_close(at_alt.pixels[0], 2.0F, 1.0e-6F,
                "alternate-headroom endpoint did not produce w=1");
  require_close(above_alt.pixels[0], 2.0F, 1.0e-6F,
                "headroom above alternate did not clamp to w=1");

  // The gain at code 0.5 is one stop. These are physical-H samples, not
  // samples chosen to share a decoder weight across files.
  for (const auto& [headroom, expected] : {
           std::pair{0.5F, std::pow(2.0F, 0.25F)},
           std::pair{1.0F, std::sqrt(2.0F)},
           std::pair{1.5F, std::pow(2.0F, 0.75F)},
       }) {
    const auto rendered = hyperdr::reconstruct_gain_map(
        base, gain, metadata, headroom);
    require_close(rendered.pixels[0], expected, 1.0e-6F,
                  "interior physical-headroom value was incorrect");
  }
}

void test_negative_gain_clamp() {
  auto metadata = positive_metadata();
  metadata.gain_min = {-1, 1};
  metadata.gain_max = {-1, 1};
  metadata.alternate_offset = {2, 1};

  const auto rendered = hyperdr::reconstruct_gain_map(
      base_image(1.0F), gain_image(1.0F), metadata, 2.0F);
  for (const float sample : rendered.pixels) {
    require(sample == 0.0F, "negative reconstructed channel was not clamped");
  }
}

void test_reverse_headroom_order_uses_the_same_endpoint_weight() {
  auto metadata = positive_metadata();
  metadata.base_headroom = {2, 1};
  metadata.alternate_headroom = {0, 1};

  const auto rendered = hyperdr::reconstruct_gain_map(
      base_image(1.0F), gain_image(1.0F), metadata, 1.0F);
  require_close(rendered.pixels[0], 2.0F, 1.0e-6F,
                "reverse headroom order inverted the interpolation weight");
}

void test_gamma_interpolation_order_is_code_domain() {
  auto metadata = positive_metadata();
  metadata.gamma = {2, 1};
  hyperdr::FloatImage gain(2, 1, 1);
  gain.pixels[0] = 0.0F;
  gain.pixels[1] = 1.0F;
  hyperdr::FloatImage base(4, 1, 3);
  for (float& sample : base.pixels) sample = 1.0F;

  // T2 was adjudicated on 2026-08-09: macOS 26 Core Image, handed the
  // native-resolution gain map so that it performs the upsampling itself,
  // matches code-domain interpolation to floating-point noise, while the
  // decoded-domain hypothesis is four orders of magnitude worse at every
  // registered headroom. The order is no longer a convention this fixture
  // declines to choose; it is decoder behaviour the renderer is held to.
  // Verdict, competing hypothesis and scope:
  // HyperDR_Model/reports/macos-t2-interpolation-verdict.json.
  //
  // A four-wide base over a two-wide gain map puts the sample centres at codes
  // 0, 0.25, 0.75 and 1. Only the interior pair discriminates; the endpoints
  // agree under either order because there is nothing there to interpolate.
  const auto rendered =
      hyperdr::reconstruct_gain_map(base, gain, metadata, 2.0F);
  require_close(rendered.pixels[0], 1.0F, 1.0e-6F,
                "gamma fixture changed the zero-code endpoint");
  require_close(rendered.pixels[9], 4.0F, 1.0e-6F,
                "gamma fixture changed the one-code endpoint");

  for (const auto& [pixel, code] : {
           std::pair{1U, 0.25F},
           std::pair{2U, 0.75F},
       }) {
    // Interpolate codes, then invert the gamma: log_gain = 2 * sqrt(code).
    const float code_domain = std::exp2(2.0F * std::sqrt(code));
    // The registered alternative, as implemented in tests/macos_t2/
    // cpp_reference.cpp: invert the gamma at each gain sample first, then
    // interpolate, then map into [gain_min, gain_max].
    const float decoded_domain = std::exp2(2.0F * code);

    require_close(rendered.pixels[pixel * 3U], code_domain, 1.0e-6F,
                  "interior pixel did not follow code-domain interpolation");
    // Guard the fixture, not only the renderer. The endpoint-only version of
    // this test could not have answered the question it was named after; if a
    // future geometry change stops the two orders from disagreeing here, this
    // fails loudly instead of passing vacuously.
    require(std::abs(code_domain - decoded_domain) > 0.4F,
            "fixture no longer separates the two interpolation orders");
  }
}

void test_clamp_statistics_are_reported() {
  // A render with nothing to clamp must say so, or a zero clamp count means
  // "not measured" and "measured zero" at the same time.
  hyperdr::ReconstructionStats quiet{};
  (void)hyperdr::reconstruct_gain_map(base_image(1.0F), gain_image(0.5F),
                                      positive_metadata(), 1.0F, &quiet);
  require(quiet.total_values == 3 && quiet.total_pixels == 1,
          "totals were not reported for an unclamped render");
  require(quiet.clamp_values == 0 && quiet.clamp_pixels == 0,
          "an unclamped render reported clamped samples");

  // Only the red channel goes negative. Counting values and pixels separately
  // is what makes that visible: both pixels are affected, but only two of the
  // six channel samples are. Collapsing the two counts would let a wholly
  // clamped render and a one-channel clip report the same number, and the
  // protocol compares clamp rates between arms at every headroom.
  auto metadata = positive_metadata();
  metadata.flags |= 0x80U;
  metadata.channels = {
      {{-1, 1}, {-1, 1}, {1, 1}, {0, 1}, {2, 1}},
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
  };
  hyperdr::FloatImage base(2, 1, 3);
  for (float& sample : base.pixels) sample = 1.0F;
  hyperdr::FloatImage gain(2, 1, 3);
  for (float& code : gain.pixels) code = 1.0F;

  hyperdr::ReconstructionStats stats{};
  const auto rendered =
      hyperdr::reconstruct_gain_map(base, gain, metadata, 2.0F, &stats);
  require_close(rendered.pixels[0], 0.0F, 1.0e-6F,
                "the negative red channel was not clamped");
  require_close(rendered.pixels[1], 2.0F, 1.0e-6F,
                "green was affected by red's clamp");
  require_close(rendered.pixels[2], 2.0F, 1.0e-6F,
                "blue was affected by red's clamp");
  require(stats.total_values == 6 && stats.total_pixels == 2,
          "totals did not match the image size");
  require(stats.clamp_values == 2, "clamped channel samples were miscounted");
  require(stats.clamp_pixels == 2,
          "pixels with a clamped channel were miscounted");
}

void test_three_channel_reconstruction_uses_each_channel() {
  auto metadata = positive_metadata();
  metadata.flags |= 0x80U;
  metadata.channels = {
      {{0, 1}, {0, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {2, 1}, {1, 1}, {0, 1}, {0, 1}},
  };
  hyperdr::FloatImage gain(1, 1, 3);
  for (float& code : gain.pixels) code = 1.0F;

  const auto rendered = hyperdr::reconstruct_gain_map(
      base_image(1.0F), gain, metadata, 2.0F);
  require_close(rendered.pixels[0], 1.0F, 1.0e-6F,
                "red reconstruction did not use red metadata");
  require_close(rendered.pixels[1], 2.0F, 1.0e-6F,
                "green reconstruction fell back to channel zero");
  require_close(rendered.pixels[2], 4.0F, 1.0e-6F,
                "blue reconstruction fell back to channel zero");
}

void test_channel_mismatch_is_rejected() {
  auto metadata = positive_metadata();
  metadata.flags |= 0x80U;
  metadata.channels = {
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
      {{0, 1}, {1, 1}, {1, 1}, {0, 1}, {0, 1}},
  };
  bool rejected = false;
  try {
    (void)hyperdr::reconstruct_gain_map(
        base_image(1.0F), gain_image(1.0F), metadata, 1.0F);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected,
          "three-channel metadata silently consumed a one-channel gain map");

  hyperdr::FloatImage rgb_gain(1, 1, 3);
  rejected = false;
  try {
    (void)hyperdr::reconstruct_gain_map(
        base_image(1.0F), rgb_gain, positive_metadata(), 1.0F);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected,
          "one-channel metadata silently consumed a three-channel gain map");
}

void test_large_image_uses_shared_double_precision_coordinates() {
  constexpr std::uint32_t kWidth = 1'500'000;
  constexpr std::uint32_t kGainWidth = 3068;
  hyperdr::FloatImage base(kWidth, 1, 3);
  std::fill(base.pixels.begin(), base.pixels.end(), 1.0F);
  hyperdr::FloatImage gain(kGainWidth, 1, 1);
  for (std::uint32_t x = 0; x < kGainWidth; ++x) {
    gain.at(x, 0, 0) = static_cast<float>(x) /
                       static_cast<float>(kGainWidth - 1U);
  }
  const auto rendered = hyperdr::reconstruct_gain_map(
      base, gain, positive_metadata(), 2.0F);
  for (const std::uint32_t x : {1'000'013U, 1'234'567U, kWidth - 1U}) {
    const auto c = hyperdr::bilinear_grid_coordinates(
        kGainWidth, 1, kWidth, 1, x, 0);
    const float code = std::lerp(gain.at(c.x0, 0, 0),
                                 gain.at(c.x1, 0, 0), c.tx);
    require_close(rendered.at(x, 0, 0), std::exp2(2.0F * code), 2.0e-5F,
                  "reconstruction diverged from shared large-image coordinates");
  }
}

}  // namespace

int main() {
  try {
    test_physical_headroom_weight();
    test_negative_gain_clamp();
    test_reverse_headroom_order_uses_the_same_endpoint_weight();
    test_gamma_interpolation_order_is_code_domain();
    test_clamp_statistics_are_reported();
    test_three_channel_reconstruction_uses_each_channel();
    test_channel_mismatch_is_rejected();
    test_large_image_uses_shared_double_precision_coordinates();
    std::cout << "synthetic reconstruction tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "synthetic reconstruction test failure: " << error.what() << '\n';
    return 1;
  }
}
