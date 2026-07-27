// A whole-chain guard.
//
// The existing tests check individual properties -- curve monotonicity, gamma
// round trips, local gain behaviour -- but nothing fails when the *composition*
// of those stages changes. Rendering a fixed synthetic scene and comparing
// aggregate statistics catches "the colour chain moved" without needing binary
// fixtures in the repository.
//
// The tolerances are deliberately loose enough to absorb the last bits of
// floating-point difference between compilers, and tight enough that a real
// change in exposure, contrast, gain distribution or headroom trips them. When
// a change here is intentional, update the constants in the same commit and say
// why in the message.

#include "hyperdr/gainmap/gain_map.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

// A scene with a deep shadow ramp, a diffuse midtone field, saturated colour,
// and a small specular highlight well above diffuse white -- i.e. one of each
// thing the look is supposed to treat differently.
hyperdr::FloatImage synthetic_scene(std::uint32_t width, std::uint32_t height) {
  hyperdr::FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    const float v = static_cast<float>(y) / static_cast<float>(height - 1);
    for (std::uint32_t x = 0; x < width; ++x) {
      const float u = static_cast<float>(x) / static_cast<float>(width - 1);
      // Horizontal exposure ramp over roughly ten stops.
      const float level = 0.002F * std::exp2(u * 10.0F);
      // Vertical hue sweep so vibrance and gamut handling are exercised.
      const float r = level * (0.55F + 0.45F * std::cos(6.2831853F * v));
      const float g = level * (0.55F + 0.45F * std::cos(6.2831853F * (v + 0.333F)));
      const float b = level * (0.55F + 0.45F * std::cos(6.2831853F * (v + 0.667F)));
      image.at(x, y, 0) = r;
      image.at(x, y, 1) = g;
      image.at(x, y, 2) = b;
    }
  }
  // Specular highlight: a small, very bright disc that only the HDR rendition
  // should be able to hold.
  const float cx = width * 0.7F;
  const float cy = height * 0.35F;
  const float radius = std::min(width, height) * 0.08F;
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const float dx = static_cast<float>(x) - cx;
      const float dy = static_cast<float>(y) - cy;
      if (dx * dx + dy * dy > radius * radius) continue;
      for (std::uint32_t c = 0; c < 3; ++c) image.at(x, y, c) = 24.0F;
    }
  }
  return image;
}

double mean_of(const std::vector<float>& values) {
  if (values.empty()) return 0.0;
  double sum = 0.0;
  for (const float value : values) sum += value;
  return sum / static_cast<double>(values.size());
}

float percentile_of(std::vector<float> values, double fraction) {
  if (values.empty()) return 0.0F;
  const auto index = std::min(values.size() - 1,
                              static_cast<std::size_t>(fraction * (values.size() - 1)));
  std::nth_element(values.begin(), values.begin() + static_cast<std::ptrdiff_t>(index),
                   values.end());
  return values[index];
}

void close_to(double actual, double expected, double tolerance, const std::string& what) {
  if (std::abs(actual - expected) <= tolerance) return;
  std::array<char, 256> message{};
  std::snprintf(message.data(), message.size(),
                "%s drifted: expected %.6f +/- %.6f, got %.6f", what.c_str(), expected,
                tolerance, actual);
  throw std::runtime_error(message.data());
}

struct Digest {
  double base_mean{};
  double base_p50{};
  double base_p99{};
  double gain_mean{};
  double gain_p95{};
  double gain_max{};
  double exposure_ev{};
  double headroom_stops{};
  double rendered_peak{};
};

Digest render(const hyperdr::GainMapOptions& options) {
  const auto scene = synthetic_scene(192, 128);
  const auto result = hyperdr::make_gain_map(scene, options, {});
  require(result.base_linear.width == 192 && result.base_linear.height == 128,
          "unexpected rendered size");

  Digest digest;
  digest.base_mean = mean_of(result.base_linear.pixels);
  digest.base_p50 = percentile_of(result.base_linear.pixels, 0.50);
  digest.base_p99 = percentile_of(result.base_linear.pixels, 0.99);
  digest.gain_mean = mean_of(result.gain_map.pixels);
  digest.gain_p95 = percentile_of(result.gain_map.pixels, 0.95);
  digest.gain_max = *std::max_element(result.gain_map.pixels.begin(),
                                      result.gain_map.pixels.end());
  digest.exposure_ev = result.exposure_ev;
  digest.headroom_stops = result.headroom_stops;
  digest.rendered_peak = result.stats.rendered_peak;

  // Invariants that must hold whatever the tuning is.
  for (const float value : result.base_linear.pixels) {
    require(std::isfinite(value) && value >= 0.0F && value <= 1.0F + 1.0e-5F,
            "the SDR base must stay finite and within [0,1]");
  }
  for (const float value : result.gain_map.pixels) {
    require(std::isfinite(value) && value >= 0.0F && value <= 1.0F + 1.0e-5F,
            "the gain map must stay finite and within [0,1]");
  }
  require(digest.rendered_peak >= 1.0, "the rendered peak must be at least diffuse white");
  return digest;
}

void print(const char* label, const Digest& d) {
  std::cout << label << ": base_mean=" << d.base_mean << " base_p50=" << d.base_p50
            << " base_p99=" << d.base_p99 << " gain_mean=" << d.gain_mean
            << " gain_p95=" << d.gain_p95 << " gain_max=" << d.gain_max
            << " exposure_ev=" << d.exposure_ev << " headroom=" << d.headroom_stops
            << " rendered_peak=" << d.rendered_peak << '\n';
}

// Two renders of the same scene must agree bit for bit; the row-parallel stages
// are only allowed to be deterministic.
void check_determinism(const hyperdr::GainMapOptions& options) {
  const auto scene = synthetic_scene(96, 64);
  const auto first = hyperdr::make_gain_map(scene, options, {});
  const auto second = hyperdr::make_gain_map(scene, options, {});
  require(first.base_linear.pixels == second.base_linear.pixels,
          "the SDR base must be reproducible bit for bit");
  require(first.gain_map.pixels == second.gain_map.pixels,
          "the gain map must be reproducible bit for bit");
}

hyperdr::GainMapOptions photographic_defaults() {
  hyperdr::GainMapOptions options;
  options.auto_exposure = false;
  options.exposure_ev = 0.0F;
  options.exposure_bias_ev = 1.0F;
  options.auto_headroom = false;
  options.headroom_stops = 3.0F;
  return options;
}

}  // namespace

int main(int argc, char** argv) {
  const bool print_only = argc > 1 && std::string(argv[1]) == "--print";
  try {
    auto options = photographic_defaults();
    const auto photographic = render(options);

    options.look.mode = hyperdr::LookMode::kNeutral;
    const auto neutral = render(options);

    if (print_only) {
      print("photographic", photographic);
      print("neutral", neutral);
      return 0;
    }

    // Recorded from the reference build (GCC 11, Release, core-only). See the
    // file header before changing any of these.
    close_to(photographic.base_mean, 0.242810, 0.004, "photographic base mean");
    close_to(photographic.base_p50, 0.032887, 0.003, "photographic base p50");
    close_to(photographic.base_p99, 1.000000, 0.004, "photographic base p99");
    close_to(photographic.gain_mean, 0.050364, 0.004, "photographic gain mean");
    close_to(photographic.gain_p95, 0.274510, 0.008, "photographic gain p95");
    close_to(photographic.gain_max, 1.000000, 0.004, "photographic gain max");
    close_to(photographic.exposure_ev, 1.000000, 0.002, "photographic exposure");
    close_to(photographic.headroom_stops, 2.993880, 0.020, "photographic headroom");
    // Local highlight weighting is allowed to land below the nominal target,
    // but the specular disc must still reach well past diffuse white.
    require(photographic.rendered_peak > 4.0,
            "the specular highlight should reach into the HDR headroom");

    close_to(neutral.base_mean, 0.210281, 0.004, "neutral base mean");
    close_to(neutral.gain_mean, 0.075224, 0.004, "neutral gain mean");
    close_to(neutral.headroom_stops, 3.000000, 0.020, "neutral headroom");

    // The two looks must stay distinguishable; collapsing them would mean the
    // rollback path silently stopped being a rollback path.
    require(std::abs(photographic.base_mean - neutral.base_mean) > 0.005,
            "photographic and neutral renders should not be identical");

    check_determinism(photographic_defaults());
  } catch (const std::exception& e) {
    std::cerr << "render_regression_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "render_regression_test passed\n";
  return 0;
}
