#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::FloatImage highlight_scene() {
  // Both the full-resolution path and the half-resolution grid exceed the
  // row helper's parallel-work threshold.
  hyperdr::FloatImage source(512, 256, 3);
  for (std::uint32_t y = 0; y < source.height; ++y) {
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const float t = static_cast<float>(x) / static_cast<float>(source.width - 1);
      const float base = 0.05F + 3.5F * t;
      source.at(x, y, 0) = base * 1.00F;
      source.at(x, y, 1) = base * (0.50F + 0.30F * y / source.height);
      source.at(x, y, 2) = base * 0.20F;
    }
  }
  for (std::uint32_t y = 58; y < 62; ++y) {
    for (std::uint32_t x = 98; x < 102; ++x) {
      source.at(x, y, 0) = 30.0F;
      source.at(x, y, 1) = 22.0F;
      source.at(x, y, 2) = 10.0F;
    }
  }
  // A controlled saturated Display P3 patch makes the input-domain metric
  // exercise an unambiguously Rec.709-outside chromaticity.
  for (std::uint32_t y = 8; y < 24; ++y) {
    for (std::uint32_t x = 8; x < 24; ++x) {
      source.at(x, y, 0) = 0.0F;
      source.at(x, y, 1) = 1.0F;
      source.at(x, y, 2) = 0.0F;
    }
  }
  return source;
}
}  // namespace

int main() {
  try {
    using namespace hyperdr;
    const auto src = highlight_scene();

    // P4: the row-parallel renderer must be bit-for-bit deterministic.
    GainMapOptions base_options;
    const auto first = make_gain_map(src, base_options);
    const auto second = make_gain_map(src, base_options);
    require(first.base_linear.pixels == second.base_linear.pixels &&
                first.gain_map.pixels == second.gain_map.pixels,
            "make_gain_map is not deterministic across runs");

    // P3: pop is validated in [0, 1].
    auto rejected = [](GainMapOptions g) {
      try {
        validate_gain_map_options(g);
      } catch (const std::invalid_argument&) {
        return true;
      }
      return false;
    };
    GainMapOptions too_high = base_options;
    too_high.look.pop = 1.5F;
    require(rejected(too_high), "pop above 1 was not rejected");
    GainMapOptions not_finite = base_options;
    not_finite.look.pop = std::numeric_limits<float>::quiet_NaN();
    require(rejected(not_finite), "NaN pop was not rejected");
    GainMapOptions accepted = base_options;
    accepted.look.pop = 1.0F;
    validate_gain_map_options(accepted);

    GainMapOptions start_too_low = base_options;
    start_too_low.look.shoulder_start = 0.17F;
    require(rejected(start_too_low), "expansion start below 0.18 was not rejected");
    GainMapOptions start_too_high = base_options;
    start_too_high.look.shoulder_start = 0.76F;
    require(rejected(start_too_high), "expansion start above 0.75 was not rejected");
    GainMapOptions coverage_too_high = base_options;
    coverage_too_high.look.diffuse_gain_floor = 1.01F;
    require(rejected(coverage_too_high), "area coverage above 1 was not rejected");
    GainMapOptions bias_too_high = base_options;
    bias_too_high.exposure_bias_ev = 2.01F;
    require(rejected(bias_too_high), "exposure bias above 2 EV was not rejected");
    GainMapOptions bias_too_low = base_options;
    bias_too_low.exposure_bias_ev = -0.01F;
    require(rejected(bias_too_low), "negative exposure bias was not rejected");
    GainMapOptions bias_not_finite = base_options;
    bias_not_finite.exposure_bias_ev = std::numeric_limits<float>::quiet_NaN();
    require(rejected(bias_not_finite), "NaN exposure bias was not rejected");
    GainMapOptions custom_region = base_options;
    custom_region.look.shoulder_start = 0.18F;
    custom_region.look.diffuse_gain_floor = 1.0F;
    validate_gain_map_options(custom_region);

    // P3: the soft shoulder may cross a gain-grid boundary, but the transition
    // below the nominal knee must remain visually negligible.
    const auto popped = make_gain_map(src, accepted);
    require(popped.stats.below_knee_relative_difference_max < 0.08F,
            "pop leaked excessive gain below the shoulder transition");

    // P3: pop pushes HDR at least as hard as the restrained default.
    require(popped.stats.headroom_stops + 1.0e-4F >=
                first.stats.headroom_stops,
            "pop reduced the requested headroom");

    // The two public controls must have distinct, measurable semantics.
    GainMapOptions weak = base_options;
    weak.auto_exposure = false;
    weak.auto_headroom = false;
    weak.headroom_stops = 3.0F;
    weak.gain_strength = 0.25F;
    weak.look.pop = 0.25F;
    const auto weak_result = make_gain_map(src, weak);
    auto strong = weak;
    strong.gain_strength = 0.80F;
    strong.look.pop = 0.80F;
    const auto strong_result = make_gain_map(src, strong);
    require(strong_result.headroom_stops > weak_result.headroom_stops + 1.0F,
            "HDR strength did not produce a perceptible peak change");
    require(std::abs(strong_result.headroom_stops - 2.40F) < 0.15F,
            "HDR strength did not reach its target content headroom");

    auto short_range = strong;
    short_range.headroom_stops = 1.0F;
    const auto short_result = make_gain_map(src, short_range);
    require(strong_result.headroom_stops > short_result.headroom_stops + 1.0F,
            "HDR range did not produce a perceptible peak change");
    require(std::abs(short_result.headroom_stops - 0.80F) < 0.15F,
            "HDR range did not reach its target content headroom");

    GainMapOptions baseline_brightness = strong;
    baseline_brightness.auto_exposure = false;
    baseline_brightness.exposure_ev = 0.0F;
    baseline_brightness.exposure_bias_ev = 1.0F;
    const auto baseline_brightness_result = make_gain_map(src, baseline_brightness);
    auto brighter = baseline_brightness;
    brighter.exposure_bias_ev = 1.75F;
    const auto brighter_result = make_gain_map(src, brighter);
    require(std::abs(brighter_result.exposure_ev - baseline_brightness_result.exposure_ev -
                     0.75F) <
                1.0e-5F,
            "exposure bias was not applied after exposure selection");

    // P3: single-channel common-RGB reconstruction still preserves chromaticity.
    const auto rec = reconstruct_gain_map(popped.base_linear, popped.gain_map,
                                          popped.metadata, popped.headroom_stops);
    const std::size_t pixels =
        static_cast<std::size_t>(popped.base_linear.width) * popped.base_linear.height;
    for (std::size_t px = 0; px < pixels; ++px) {
      const std::size_t k = px * 3;
      if (popped.base_linear.pixels[k] > 1.0e-5F &&
          popped.base_linear.pixels[k + 1] > 1.0e-5F &&
          popped.base_linear.pixels[k + 2] > 1.0e-5F) {
        const float rr = rec.pixels[k] / popped.base_linear.pixels[k];
        const float rg = rec.pixels[k + 1] / popped.base_linear.pixels[k + 1];
        const float rb = rec.pixels[k + 2] / popped.base_linear.pixels[k + 2];
        require(std::abs(rr - rg) < 2.0e-5F && std::abs(rr - rb) < 2.0e-5F,
                "pop reconstruction changed chromaticity");
      }
    }

    // Neutral must ignore pop, like the other photographic controls.
    GainMapOptions neutral = base_options;
    neutral.look.mode = LookMode::kNeutral;
    const auto neutral_base = make_gain_map(src, neutral);
    GainMapOptions neutral_pop = neutral;
    neutral_pop.look.pop = 1.0F;
    const auto neutral_ignored = make_gain_map(src, neutral_pop);
    require(neutral_base.base_linear.pixels == neutral_ignored.base_linear.pixels &&
                neutral_base.gain_map.pixels == neutral_ignored.gain_map.pixels,
            "neutral path was affected by pop");

    require(first.stats.wide_gamut_fraction > 0.0F &&
                first.stats.wide_gamut_fraction <= 1.0F,
            "wide_gamut_fraction is not a valid fraction");

    require(first.stats.wide_gamut_fraction == second.stats.wide_gamut_fraction &&
                first.stats.wide_gamut_pixels == second.stats.wide_gamut_pixels &&
                first.stats.wide_gamut_eligible_pixels == second.stats.wide_gamut_eligible_pixels,
            "wide-gamut input metric is not deterministic");
    require(first.stats.wide_gamut_fraction == popped.stats.wide_gamut_fraction &&
                first.stats.wide_gamut_pixels == popped.stats.wide_gamut_pixels &&
                first.stats.wide_gamut_eligible_pixels == popped.stats.wide_gamut_eligible_pixels &&
                first.stats.wide_gamut_fraction == neutral_base.stats.wide_gamut_fraction,
            "wide-gamut input metric was affected by look or pop");
    std::cout << "pop/parallel tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "pop/parallel test failure: " << error.what() << '\n';
    return 1;
  }
}
