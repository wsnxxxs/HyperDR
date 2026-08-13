#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/container/iso_gain_map.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_gain_map_and_metadata() {
  hyperdr::FloatImage source(8, 8, 3);
  for (std::uint32_t y = 0; y < source.height; ++y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const float value = 0.05F + 3.5F * x / static_cast<float>(source.width - 1);
      source.at(x, y, 0) = value;
      source.at(x, y, 1) = value * 0.8F;
      source.at(x, y, 2) = value * 0.6F;
    }
  }
  hyperdr::GainMapOptions options;
  options.auto_exposure = false;
  options.auto_headroom = false;
  options.headroom_stops = 2.0F;
  const auto result = hyperdr::make_gain_map(source, options);
  require(result.gain_map.width == 4 && result.gain_map.height == 4, "gain-map downsample dimensions failed");
  for (const float value : result.gain_map.pixels)
    require(std::isfinite(value) && value >= 0.0F && value <= 1.0F, "gain-map range failed");

  const auto payload = hyperdr::serialize_tmap_payload(result.metadata);
  require(payload.size() == 62, "single-channel ISO metadata size failed");
  const auto parsed = hyperdr::parse_tmap_payload(payload);
  require(parsed.gain_max.numerator == result.metadata.gain_max.numerator, "metadata round trip failed");
  auto gamma_metadata = result.metadata;
  gamma_metadata.gamma = {3, 2};
  const auto gamma_payload = hyperdr::serialize_tmap_payload(gamma_metadata);
  const auto parsed_gamma = hyperdr::parse_tmap_payload(gamma_payload);
  require(parsed_gamma.gamma.numerator == 3 && parsed_gamma.gamma.denominator == 2,
          "gain gamma metadata round trip failed");
  const auto reconstructed = hyperdr::reconstruct_gain_map(result.base_linear, result.gain_map,
                                                            parsed, result.headroom_stops);
  for (const float value : reconstructed.pixels) require(std::isfinite(value) && value >= 0.0F, "reconstruction range failed");
}

void test_color_preservation_and_headroom() {
  hyperdr::GainMapOptions options;
  options.auto_exposure = false;
  options.auto_headroom = false;
  options.headroom_stops = 3.0F;

  // Low-luminance saturated HDR values force gamut limiting but must keep a
  // common RGB scale. HyperDR's Apple-targeted writer uses the gain interval as
  // its alternate capacity even when the measured luminance peak stays at SDR.
  // Written at the values the renderer is meant to see, with the creative
  // offset pinned off. This used to be 1.0 / 0.1 / 0.1 and relied on
  // exposure_bias_ev defaulting to +1 EV to double it, so the case silently
  // measured something else the moment that default was corrected to 0.
  options.exposure_bias_ev = 0.0F;
  hyperdr::FloatImage saturated(2, 2, 3);
  for (std::size_t i = 0; i < 4; ++i) {
    saturated.pixels[i * 3] = 2.0F;
    saturated.pixels[i * 3 + 1] = 0.2F;
    saturated.pixels[i * 3 + 2] = 0.2F;
  }
  const auto saturated_result = hyperdr::make_gain_map(saturated, options);
  const float r = saturated_result.base_linear.pixels[0];
  const float g = saturated_result.base_linear.pixels[1];
  const float b = saturated_result.base_linear.pixels[2];
  // Photographic compresses this 10:1 input towards white on purpose, so the
  // input ratio is not preserved -- what must survive is the hue. The two equal
  // input channels have to stay exactly equal, red has to stay dominant, and the
  // compression must not run so far that the colour is flattened or inverted.
  require(g == b, "gamut compression split two equal channels apart");
  require(r > g, "gamut compression did not keep red dominant");
  const float ratio = r / g;
  require(ratio > 1.5F && ratio < 4.0F,
          "gamut compression left the saturated patch flat or over-saturated");
  const float gain_max =
      static_cast<float>(saturated_result.metadata.gain_max.numerator) /
      saturated_result.metadata.gain_max.denominator;
  const float headroom =
      static_cast<float>(saturated_result.metadata.alternate_headroom.numerator) /
      saturated_result.metadata.alternate_headroom.denominator;
  require(gain_max > 0.1F && std::abs(headroom - gain_max) < 1.0e-6F,
          "photographic output violated Apple's gain/headroom convention");

  // An achromatic HDR patch has positive luminance headroom and should
  // round-trip. Every pixel is the brightest one, so reconstructing at the
  // declared headroom must reproduce the peak the renderer reports rather than
  // a constant copied out of one renderer's arithmetic.
  hyperdr::FloatImage achromatic(2, 2, 3);
  std::fill(achromatic.pixels.begin(), achromatic.pixels.end(), 1.0F);
  const auto flat = hyperdr::make_gain_map(achromatic, options);
  const auto reconstructed = hyperdr::reconstruct_gain_map(
      flat.base_linear, flat.gain_map, flat.metadata, flat.headroom_stops);
  require(flat.stats.rendered_peak > 1.0F,
          "an achromatic HDR patch produced no expansion at all");
  for (const float value : reconstructed.pixels) {
    require(std::abs(value - flat.stats.rendered_peak) < 1.0e-3F,
            "achromatic HDR round trip did not reproduce the rendered peak");
  }
}

void test_bilinear_gain_sampling() {
  hyperdr::FloatImage base(4, 1, 3);
  std::fill(base.pixels.begin(), base.pixels.end(), 0.25F);
  hyperdr::FloatImage gain(2, 1, 1);
  gain.at(0, 0, 0) = 0.0F;
  gain.at(1, 0, 0) = 1.0F;
  hyperdr::GainMapMetadata metadata;
  metadata.gain_min = {0, 1};
  metadata.gain_max = {1, 1};
  metadata.base_offset = {0, 1};
  metadata.alternate_offset = {0, 1};
  metadata.base_headroom = {0, 1};
  metadata.alternate_headroom = {1, 1};
  const auto output = hyperdr::reconstruct_gain_map(base, gain, metadata, 1.0F);
  require(output.at(0, 0, 0) < output.at(1, 0, 0) &&
              output.at(1, 0, 0) < output.at(2, 0, 0) &&
              output.at(2, 0, 0) < output.at(3, 0, 0),
          "gain map was not bilinearly interpolated");
}

void test_black_and_nan_guards() {
  hyperdr::FloatImage black(3, 3, 3);
  black.pixels[0] = std::numeric_limits<float>::quiet_NaN();
  const auto result = hyperdr::make_gain_map(black, {});
  for (const float value : result.base_linear.pixels) require(std::isfinite(value), "NaN reached base output");
  for (const float value : result.gain_map.pixels) require(std::isfinite(value), "NaN reached gain output");
}

// alternate_headroom used to be measured before the percentile trim, so it
// could promise highlights the encoded gain map had no way to reproduce. This
// is the reported reproduction: a single hot pixel in a flat field, which the
// 99.9th-percentile trim discards entirely.
void test_encoded_headroom_matches_the_gain_map() {
  hyperdr::FloatImage source(100, 100, 3);
  for (std::size_t i = 0; i < source.pixels.size(); ++i) source.pixels[i] = 0.1F;
  source.at(99, 99, 0) = 100.0F;
  source.at(99, 99, 1) = 100.0F;
  source.at(99, 99, 2) = 100.0F;

  hyperdr::GainMapOptions options;
  options.auto_exposure = false;
  options.exposure_ev = 0.0F;
  options.exposure_bias_ev = 0.0F;
  options.auto_headroom = false;
  options.headroom_stops = 3.0F;
  options.gain_strength = 1.0F;

  const auto result = hyperdr::make_gain_map(source, options);
  const float declared =
      static_cast<float>(result.metadata.alternate_headroom.numerator) /
      static_cast<float>(result.metadata.alternate_headroom.denominator);
  require(std::abs(declared - result.headroom_stops) < 1.0e-4F,
          "the metadata and the result must report one headroom");
  require(std::abs(declared - hyperdr::rational_value(result.metadata.gain_max)) <
              1.0e-6F,
          "Apple-targeted output must use one gain/headroom ceiling");
  require(declared <= options.headroom_stops + 1.0e-5F,
          "gain metadata exceeded the requested headroom");

  // What the gain map can actually reconstruct, computed independently of the
  // renderer: the largest stored code applied to the brightest base pixel.
  const float gain_min =
      static_cast<float>(result.metadata.gain_min.numerator) /
      static_cast<float>(result.metadata.gain_min.denominator);
  const float gain_max =
      static_cast<float>(result.metadata.gain_max.numerator) /
      static_cast<float>(result.metadata.gain_max.denominator);
  float peak_code = 0.0F;
  for (const float code : result.gain_map.pixels) peak_code = std::max(peak_code, code);
  const float peak_gain = gain_min + peak_code * (gain_max - gain_min);
  const float reconstructable = std::max(0.0F, peak_gain);

  require(declared <= reconstructable + 0.05F,
          "declared headroom must not exceed what the gain map encodes");

  // And the specific failure: every code trimmed away means no headroom claim.
  if (peak_code <= 0.0F && gain_max <= gain_min + 1.0e-6F) {
    require(declared < 0.05F,
            "an all-zero gain map cannot declare highlight headroom");
  }
}

// A manual headroom above the configured ceiling used to be accepted, reported
// at the requested value, and then rendered at the ceiling -- so the file
// disagreed with everything describing it. Rejecting is the only answer that
// leaves the request and the result the same number.
void test_manual_headroom_above_the_ceiling_is_rejected() {
  hyperdr::GainMapOptions options;
  options.auto_headroom = false;
  options.look.headroom_max_stops = 3.0F;
  options.headroom_stops = 4.0F;
  bool threw = false;
  try {
    hyperdr::validate_gain_map_options(options);
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "a headroom above headroom-max must be rejected");

  options.headroom_stops = options.look.headroom_max_stops;
  hyperdr::validate_gain_map_options(options);

  // Under auto-headroom the nominal value is the configured ceiling itself.
  options.auto_headroom = true;
  require(std::abs(hyperdr::nominal_headroom_stops(options) - 3.0F) < 1.0e-6F,
          "the nominal headroom reported is the configured ceiling");
}

}  // namespace

int main() {
  try {
    test_gain_map_and_metadata();
    test_color_preservation_and_headroom();
    test_bilinear_gain_sampling();
    test_black_and_nan_guards();
    test_encoded_headroom_matches_the_gain_map();
    test_manual_headroom_above_the_ceiling_is_rejected();
    std::cout << "gain-map tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
