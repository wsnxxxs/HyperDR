#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"

#include <cmath>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::FloatImage colorful_source() {
  hyperdr::FloatImage source(32, 16, 3);
  for (std::uint32_t y = 0; y < source.height; ++y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const float intensity = 0.08F + 7.0F * x / static_cast<float>(source.width - 1);
      source.at(x, y, 0) = intensity * 1.00F;
      source.at(x, y, 1) = intensity * (0.45F + 0.15F * y / source.height);
      source.at(x, y, 2) = intensity * 0.20F;
    }
  }
  return source;
}

}  // namespace

int main() {
  try {
    const auto source = colorful_source();
    hyperdr::GainMapOptions no_headroom;
    no_headroom.auto_exposure = false;
    no_headroom.auto_headroom = false;
    no_headroom.headroom_stops = 0.0F;
    const auto sdr_only = hyperdr::make_gain_map(source, no_headroom);
    require(sdr_only.metadata.base_offset.numerator == 0 &&
                sdr_only.metadata.alternate_offset.numerator == 0,
            "photographic path did not use zero offsets");
    for (const float code : sdr_only.gain_map.pixels) require(code == 0.0F, "headroom-one gain was nonzero");
    const auto reconstructed_sdr = hyperdr::reconstruct_gain_map(
        sdr_only.base_linear, sdr_only.gain_map, sdr_only.metadata, 0.0F);
    for (std::size_t i = 0; i < reconstructed_sdr.pixels.size(); ++i) {
      require(std::abs(reconstructed_sdr.pixels[i] - sdr_only.base_linear.pixels[i]) < 1.0e-6F,
              "headroom-one reconstruction changed the base image");
    }

    hyperdr::GainMapOptions photographic = no_headroom;
    photographic.headroom_stops = 3.0F;
    const auto hdr = hyperdr::make_gain_map(source, photographic);
    const auto reconstructed = hyperdr::reconstruct_gain_map(
        hdr.base_linear, hdr.gain_map, hdr.metadata, hdr.headroom_stops);
    for (std::size_t pixel = 0; pixel < hdr.base_linear.width * hdr.base_linear.height; ++pixel) {
      const std::size_t base = pixel * 3;
      if (hdr.base_linear.pixels[base] > 1.0e-5F &&
          hdr.base_linear.pixels[base + 1] > 1.0e-5F &&
          hdr.base_linear.pixels[base + 2] > 1.0e-5F) {
        const float rr = reconstructed.pixels[base] / hdr.base_linear.pixels[base];
        const float rg = reconstructed.pixels[base + 1] / hdr.base_linear.pixels[base + 1];
        const float rb = reconstructed.pixels[base + 2] / hdr.base_linear.pixels[base + 2];
        require(std::abs(rr - rg) < 2.0e-5F && std::abs(rr - rb) < 2.0e-5F,
                "photographic reconstruction changed chromaticity");
      }
    }

    hyperdr::GainMapOptions neutral = photographic;
    neutral.look.mode = hyperdr::LookMode::kNeutral;
    const auto baseline = hyperdr::make_gain_map(source, neutral);
    neutral.look.contrast = 0.80F;
    neutral.look.vibrance = -0.50F;
    neutral.look.headroom_max_stops = 0.0F;
    const auto ignored = hyperdr::make_gain_map(source, neutral);
    require(baseline.base_linear.pixels == ignored.base_linear.pixels &&
                baseline.gain_map.pixels == ignored.gain_map.pixels &&
                baseline.metadata.gain_min.numerator == ignored.metadata.gain_min.numerator &&
                baseline.metadata.gain_max.numerator == ignored.metadata.gain_max.numerator,
            "neutral path was affected by photographic controls");
    require(hyperdr::rational_value(hdr.metadata.gamma) > 0.0F, "photographic gamma metadata is invalid");

    // Complete capture metadata is used only when all three values are valid;
    // partial metadata must not be manufactured into an EV100 value.
    hyperdr::CaptureMetadata complete_capture;
    complete_capture.iso = 100.0F;
    complete_capture.exposure_time_seconds = 1.0F / 125.0F;
    complete_capture.aperture_f_number = 2.8F;
    const auto with_ev100 = hyperdr::make_gain_map(source, no_headroom, complete_capture);
    require(with_ev100.stats.ev100.has_value(), "complete capture metadata did not produce EV100");
    hyperdr::CaptureMetadata partial_capture;
    partial_capture.iso = 100.0F;
    partial_capture.aperture_f_number = 2.8F;
    const auto without_ev100 = hyperdr::make_gain_map(source, no_headroom, partial_capture);
    require(!without_ev100.stats.ev100.has_value(), "partial capture metadata produced EV100");

    auto rejected = [](const hyperdr::GainMapOptions& invalid) {
      try {
        hyperdr::validate_gain_map_options(invalid);
      } catch (const std::invalid_argument&) {
        return true;
      }
      return false;
    };
    hyperdr::GainMapOptions invalid_strength;
    invalid_strength.gain_strength = std::numeric_limits<float>::quiet_NaN();
    require(rejected(invalid_strength), "NaN gain strength was not rejected before rendering");
    hyperdr::GainMapOptions invalid_headroom;
    invalid_headroom.auto_headroom = false;
    invalid_headroom.headroom_stops = 4.1F;
    require(rejected(invalid_headroom), "manual headroom above headroom-max was not rejected");

    // This lamp covers far less than 0.01% of the 400x400 scene, so sampled
    // P99.99 alone cannot see it. The local peak/component path must retain it.
    hyperdr::FloatImage small_lamp(400, 400, 3);
    for (std::uint32_t y = 0; y < small_lamp.height; ++y) {
      for (std::uint32_t x = 0; x < small_lamp.width; ++x) {
        const float value = x >= 196 && x < 203 && y >= 196 && y < 203 ? 24.0F : 0.02F;
        small_lamp.at(x, y, 0) = value;
        small_lamp.at(x, y, 1) = value;
        small_lamp.at(x, y, 2) = value;
      }
    }
    hyperdr::CaptureMetadata low_iso;
    low_iso.iso = 100.0F;
    const auto lamp = hyperdr::make_gain_map(small_lamp, {}, low_iso);
    require(lamp.stats.headroom_stops > 0.10F,
            "small connected lamp did not receive automatic HDR headroom");
    auto hot_pixel = small_lamp;
    for (float& value : hot_pixel.pixels) value = 0.02F;
    hot_pixel.at(200, 200, 0) = 100.0F;
    hot_pixel.at(200, 200, 1) = 100.0F;
    hot_pixel.at(200, 200, 2) = 100.0F;
    hyperdr::CaptureMetadata high_iso;
    high_iso.iso = 12800.0F;
    const auto hot = hyperdr::make_gain_map(hot_pixel, {}, high_iso);
    require(hot.stats.headroom_stops < 0.01F,
            "isolated high-ISO hot pixel incorrectly requested HDR headroom");
    std::cout << "look pipeline tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "look pipeline test failure: " << error.what() << '\n';
    return 1;
  }
}
