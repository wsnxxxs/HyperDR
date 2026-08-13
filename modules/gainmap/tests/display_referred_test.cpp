// The three input domains, and what each one promises.
//
// These cases exist because the renderer used to decide the question from the
// file extension and then apply the scene-referred photographic curve to
// everything: an SDR JPEG came back with its shadows a stop down and diffuse
// white at 0.83, and a PQ HEIC came back with every value above roughly 1.5x
// diffuse white sharing the top two codes of the 8-bit base.

#include "hyperdr/gainmap/display_referred.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::GainMapOptions plain_options() {
  hyperdr::GainMapOptions options;
  options.exposure_bias_ev = 0.0F;
  return options;
}

// A gradient plus a small bright patch: enough structure that a cell mean and a
// local peak differ, which is where a grid-resolution gain map is at risk.
hyperdr::FloatImage test_image(float low, float high, float patch) {
  hyperdr::FloatImage image(64, 48, 3);
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      float value = low + (high - low) * static_cast<float>(x) /
                              static_cast<float>(image.width - 1);
      if (x >= 40 && x < 46 && y >= 20 && y < 26) value = patch;
      image.at(x, y, 0) = value;
      image.at(x, y, 1) = value * 0.92F;
      image.at(x, y, 2) = value * 0.78F;
    }
  }
  return image;
}

float peak_luminance(const hyperdr::FloatImage& image) {
  float peak = 0.0F;
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      peak = std::max(peak, 0.2289746F * image.at(x, y, 0) +
                                0.6917385F * image.at(x, y, 1) +
                                0.0792869F * image.at(x, y, 2));
    }
  }
  return peak;
}

// --- the shared shoulder ---------------------------------------------------

void test_shoulder_shape() {
  const float knee = std::log2(0.48F);
  require(hyperdr::display_shoulder_log2(knee - 2.0F, knee, 0.0F) == knee - 2.0F,
          "the shoulder must be exactly identity below its knee");
  require(hyperdr::display_shoulder_log2(knee, knee, 0.0F) == knee,
          "the shoulder must be continuous at its knee");

  // Slope 1 at the knee, so no contour appears where the two segments meet.
  const float step = 1.0e-3F;
  const float slope =
      (hyperdr::display_shoulder_log2(knee + step, knee, 0.0F) - knee) / step;
  require(std::abs(slope - 1.0F) < 5.0e-3F,
          "the shoulder must leave its knee with unit slope");

  // Monotonic, and strictly below the ceiling however far the input reaches.
  float previous = knee;
  for (float u = knee; u <= 8.0F; u += 0.05F) {
    const float value = hyperdr::display_shoulder_log2(u, knee, 0.0F);
    require(value >= previous - 1.0e-6F, "the shoulder must be monotonic");
    require(value < 0.0F, "the shoulder must stay below its ceiling");
    previous = value;
  }

  // The property the linear-domain curve did not have: a PQ input's 5.6 stops
  // still land on distinguishable 8-bit codes rather than all on 255.
  const auto code = [&](float linear) {
    const float v =
        std::exp2(hyperdr::display_shoulder_log2(std::log2(linear), knee, 0.0F));
    const float encoded = v <= 0.0031308F ? 12.92F * v
                                          : 1.055F * std::pow(v, 1.0F / 2.4F) - 0.055F;
    return static_cast<int>(std::lround(255.0F * encoded));
  };
  require(code(49.26F) - code(1.0F) >= 15,
          "a PQ-range input must keep usable code separation above diffuse white");
  require(code(49.26F) <= 255 && code(1.0F) < code(2.0F) &&
              code(2.0F) < code(49.26F),
          "highlight ordering must survive the base encoding");
}

// --- display-referred SDR --------------------------------------------------

void test_sdr_is_passed_through() {
  const auto source = test_image(0.02F, 1.0F, 1.0F);
  const auto result = hyperdr::make_gain_map(
      source, plain_options(), {},
      {hyperdr::InputDomain::kDisplayReferredSdr, 1.0F});

  require(result.base_linear.width == source.width &&
              result.base_linear.height == source.height,
          "the base must keep the input dimensions");
  float worst = 0.0F;
  for (std::size_t i = 0; i < source.pixels.size(); ++i) {
    worst = std::max(worst, std::abs(result.base_linear.pixels[i] - source.pixels[i]));
  }
  require(worst < 1.0e-6F,
          "an SDR input must reach the base unchanged, worst error " +
              std::to_string(worst));

  require(result.headroom_stops == 0.0F,
          "an SDR input must not be given headroom");
  for (const float value : result.gain_map.pixels) {
    require(value == 0.0F, "an SDR input's gain map must be exactly zero");
  }
  require(result.stats.gain_max_stops == 0.0F,
          "an SDR input must report no gain");
}

void test_sdr_brightening_rolls_off_instead_of_clipping() {
  const auto source = test_image(0.02F, 1.0F, 1.0F);
  auto options = plain_options();
  options.exposure_bias_ev = 1.0F;
  const auto result = hyperdr::make_gain_map(
      source, options, {}, {hyperdr::InputDomain::kDisplayReferredSdr, 1.0F});

  // Still no invented headroom...
  require(result.headroom_stops == 0.0F,
          "brightening an SDR input must not invent headroom");
  // ...and the highlights that no longer fit stay ordered rather than merging
  // into one clipped plate.
  const auto luminance_at = [&](std::uint32_t x, std::uint32_t y) {
    return 0.2289746F * result.base_linear.at(x, y, 0) +
           0.6917385F * result.base_linear.at(x, y, 1) +
           0.0792869F * result.base_linear.at(x, y, 2);
  };
  const std::uint32_t row = 4;
  require(luminance_at(50, row) < luminance_at(56, row) &&
              luminance_at(56, row) < luminance_at(62, row),
          "a brightened SDR gradient must not clip into a flat plate");
  for (const float value : result.base_linear.pixels) {
    require(value >= 0.0F && value <= 1.0F, "the base must stay inside [0, 1]");
  }
}

// --- display-referred HDR --------------------------------------------------

void test_hdr_keeps_its_shadows_and_restores_its_peak() {
  constexpr float kHeadroom = 4.93F;  // HLG
  const auto source = test_image(0.01F, 2.0F, kHeadroom);
  auto options = plain_options();
  options.auto_headroom = true;
  options.look.headroom_max_stops = 4.0F;
  const auto result = hyperdr::make_gain_map(
      source, options, {},
      {hyperdr::InputDomain::kDisplayReferredHdr, kHeadroom});

  require(result.stats.headroom_stops > 2.0F,
          "an HLG-range input must keep most of its declared headroom");
  require(result.stats.headroom_stops <= std::log2(kHeadroom) + 1.0e-4F,
          "the output headroom must not exceed what the input declared");

  // Below the knee the two renditions are the same function, so the gain there
  // is zero and the base is the input.
  require(result.stats.below_knee_relative_difference_max < 1.0e-3F,
          "the below-knee invariant was not preserved");
  const float knee = options.look.shoulder_start;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const float in = source.at(x, y, 1);
      if (in > knee * 0.5F) continue;
      require(std::abs(result.base_linear.at(x, y, 1) - in) < 1.0e-5F,
              "a shadow pixel must reach the base unchanged");
    }
  }

  for (const float value : result.base_linear.pixels) {
    require(value >= 0.0F && value <= 1.0F, "the base must stay inside [0, 1]");
  }

  // The reconstruction has to actually get back above diffuse white.
  const auto reconstructed = hyperdr::reconstruct_gain_map(
      result.base_linear, result.gain_map, result.metadata,
      hyperdr::rational_value(result.metadata.alternate_headroom));
  float peak = 0.0F;
  for (std::uint32_t y = 0; y < reconstructed.height; ++y) {
    for (std::uint32_t x = 0; x < reconstructed.width; ++x) {
      peak = std::max(peak, reconstructed.at(x, y, 1));
    }
  }
  require(peak > 1.5F,
          "the reconstructed rendition must exceed diffuse white, peak " +
              std::to_string(peak));
}

void test_hdr_respects_the_output_ceiling() {
  constexpr float kHeadroom = 49.26F;  // PQ
  const auto source = test_image(0.01F, 4.0F, 40.0F);
  auto options = plain_options();
  options.auto_headroom = false;
  options.headroom_stops = 2.0F;
  options.look.headroom_max_stops = 4.0F;
  const auto result = hyperdr::make_gain_map(
      source, options, {},
      {hyperdr::InputDomain::kDisplayReferredHdr, kHeadroom});

  require(result.stats.headroom_stops <= 2.0F + 1.0e-4F,
          "a requested ceiling below the input's headroom must be honoured");
  require(result.stats.headroom_stops > 1.5F,
          "the requested ceiling should be used, not abandoned");
  require(result.headroom_stops <= 2.0F + 1.0e-3F,
          "the stored gain-map maximum must respect the output ceiling");
}

// The case that caught the shoulder's original ceiling bug. When the output
// budget covers everything the input declared, the rendition has to *be* the
// input: the shoulder only approaches its ceiling, so using the target as the
// ceiling directly left a 1.06-stop input rendered at 0.42 stops. Because the
// ISO metadata declares the gain interval as the alternate headroom, that also
// shrank the declared range on every re-export -- 2.08x, then 1.34x, then 1.09x.
void test_hdr_round_trip_holds_its_headroom() {
  constexpr float kHeadroom = 4.0F;
  const auto source = test_image(0.01F, 2.0F, kHeadroom);
  auto options = plain_options();
  options.auto_headroom = true;
  options.look.headroom_max_stops = 4.0F;
  const auto result = hyperdr::make_gain_map(
      source, options, {},
      {hyperdr::InputDomain::kDisplayReferredHdr, kHeadroom});

  require(std::abs(result.stats.headroom_stops - std::log2(kHeadroom)) < 1.0e-3F,
          "a budget that covers the input must keep all of its headroom");
  // Against the luminance the pixels actually reach, not the declared ceiling:
  // the patch is chromatic, so its luminance sits below its brightest channel
  // and the gain map has no reason to carry range the picture never uses.
  const float used = std::log2(peak_luminance(source));
  require(result.headroom_stops > used - 0.05F,
          "the stored gain interval must reach the headroom the pixels use, got " +
              std::to_string(result.headroom_stops) + " for " +
              std::to_string(used));
  require(result.stats.rendered_peak > std::exp2(used) * 0.95F,
          "the rendition must reach the input's peak, got " +
              std::to_string(result.stats.rendered_peak));

  // A real second pass reads what a decoder would reconstruct, not the base.
  const auto reconstructed = hyperdr::reconstruct_gain_map(
      result.base_linear, result.gain_map, result.metadata,
      hyperdr::rational_value(result.metadata.alternate_headroom));
  const auto again = hyperdr::make_gain_map(
      reconstructed, options, {},
      {hyperdr::InputDomain::kDisplayReferredHdr,
       std::exp2(result.headroom_stops)});
  require(again.headroom_stops > result.headroom_stops - 0.05F,
          "a second pass must not shrink the declared headroom: " +
              std::to_string(result.headroom_stops) + " -> " +
              std::to_string(again.headroom_stops));
}

void test_gain_strength_scales_the_split() {
  constexpr float kHeadroom = 4.0F;
  const auto source = test_image(0.01F, 2.0F, kHeadroom);
  auto options = plain_options();
  options.auto_headroom = true;
  options.gain_strength = 0.5F;
  const auto result = hyperdr::make_gain_map(
      source, options, {},
      {hyperdr::InputDomain::kDisplayReferredHdr, kHeadroom});
  require(result.stats.headroom_stops < std::log2(kHeadroom) * 0.6F,
          "gain strength must scale the output headroom");
}

// --- routing ---------------------------------------------------------------

void test_domain_selects_the_renderer() {
  const auto source = test_image(0.02F, 0.9F, 0.9F);
  auto options = plain_options();
  options.auto_exposure = true;

  const auto scene = hyperdr::make_gain_map(
      source, options, {}, {hyperdr::InputDomain::kSceneReferred, 1.0F});
  const auto display = hyperdr::make_gain_map(
      source, options, {}, {hyperdr::InputDomain::kDisplayReferredSdr, 1.0F});
  require(scene.exposure_ev != 0.0F,
          "the scene-referred renderer must still choose an exposure");
  require(display.exposure_ev == 0.0F,
          "a display-referred input must not be automatically re-exposed");
  require(scene.base_linear.pixels != display.base_linear.pixels,
          "the two renderers must not produce the same base for the same pixels");
}

void test_headroom_must_match_the_domain() {
  const auto source = test_image(0.02F, 0.9F, 0.9F);
  bool rejected = false;
  try {
    static_cast<void>(hyperdr::make_gain_map(
        source, plain_options(), {},
        {hyperdr::InputDomain::kDisplayReferredHdr, 1.0F}));
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "an HDR domain with unit headroom must be rejected");

  rejected = false;
  try {
    static_cast<void>(hyperdr::make_gain_map(
        source, plain_options(), {},
        {hyperdr::InputDomain::kDisplayReferredSdr, 4.0F}));
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "a non-HDR domain must not carry headroom");
}

}  // namespace

int main() {
  try {
    test_shoulder_shape();
    test_sdr_is_passed_through();
    test_sdr_brightening_rolls_off_instead_of_clipping();
    test_hdr_keeps_its_shadows_and_restores_its_peak();
    test_hdr_round_trip_holds_its_headroom();
    test_hdr_respects_the_output_ceiling();
    test_gain_strength_scales_the_split();
    test_domain_selects_the_renderer();
    test_headroom_must_match_the_domain();
  } catch (const std::exception& error) {
    std::cerr << "display_referred_test: " << error.what() << '\n';
    return 1;
  }
  std::cout << "display_referred_test passed\n";
  return 0;
}
