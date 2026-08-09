#include "hyperdr/gainmap/reconstruct.hpp"

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

void test_reverse_headroom_direction() {
  auto metadata = positive_metadata();
  metadata.base_headroom = {2, 1};
  metadata.alternate_headroom = {0, 1};

  const auto rendered = hyperdr::reconstruct_gain_map(
      base_image(1.0F), gain_image(1.0F), metadata, 1.0F);
  require_close(rendered.pixels[0], 0.5F, 1.0e-6F,
                "reverse headroom did not apply a negative weight");
}

void test_gamma_interpolation_order_is_not_assumed() {
  auto metadata = positive_metadata();
  metadata.gamma = {2, 1};
  hyperdr::FloatImage gain(2, 1, 1);
  gain.pixels[0] = 0.0F;
  gain.pixels[1] = 1.0F;
  hyperdr::FloatImage base(2, 1, 3);
  for (float& sample : base.pixels) sample = 1.0F;

  // This fixture records the unresolved T2 question rather than choosing a
  // decoder convention: endpoint samples test gamma, while cross-pixel
  // interpolation order requires an independent decoder comparison.
  const auto left = hyperdr::reconstruct_gain_map(base, gain, metadata, 2.0F);
  require_close(left.pixels[0], 1.0F, 1.0e-6F,
                "gamma fixture changed the zero-code endpoint");
  require_close(left.pixels[3], 4.0F, 1.0e-6F,
                "gamma fixture changed the one-code endpoint");
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

}  // namespace

int main() {
  try {
    test_physical_headroom_weight();
    test_negative_gain_clamp();
    test_reverse_headroom_direction();
    test_gamma_interpolation_order_is_not_assumed();
    test_three_channel_reconstruction_uses_each_channel();
    test_channel_mismatch_is_rejected();
    std::cout << "synthetic reconstruction tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "synthetic reconstruction test failure: " << error.what() << '\n';
    return 1;
  }
}
