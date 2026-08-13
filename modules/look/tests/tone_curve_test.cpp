#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/tone_curve.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void check_curve(float peak, const hyperdr::ToneCurveParameters& curve) {
  float previous = 0.0F;
  for (int i = 0; i <= 20000; ++i) {
    const float x = static_cast<float>(i) * 0.01F;
    const float value = hyperdr::render_tone_curve(x, peak, curve);
    require(std::isfinite(value), "tone curve produced a non-finite value");
    require(value + 1.0e-6F >= previous, "tone curve is not monotonic");
    require(value <= peak + 1.0e-5F, "tone curve exceeded its peak");
    previous = value;
  }
  require(hyperdr::render_tone_curve(1000.0F, peak, curve) > peak * 0.999F,
          "tone curve did not asymptotically approach its peak");
}

}  // namespace

int main() {
  try {
    const hyperdr::LookOptions options;
    const auto curve = hyperdr::build_tone_curve(options);
    require(std::abs(hyperdr::render_tone_curve(0.0F, 1.0F, curve)) < 1.0e-7F,
            "toe does not start at zero");
    require(std::abs(hyperdr::render_tone_curve(curve.toe_end, 1.0F, curve) -
                     curve.toe_output) < 1.0e-6F,
            "toe does not meet the linear segment");

    constexpr float h = 1.0e-4F;
    const float toe_left = (hyperdr::render_tone_curve(curve.toe_end, 1.0F, curve) -
                            hyperdr::render_tone_curve(curve.toe_end - h, 1.0F, curve)) / h;
    const float toe_right = (hyperdr::render_tone_curve(curve.toe_end + h, 1.0F, curve) -
                             hyperdr::render_tone_curve(curve.toe_end, 1.0F, curve)) / h;
    require(std::abs(toe_left - toe_right) < 3.0e-3F, "toe join is not C1");

    const float shoulder_left =
        (hyperdr::render_tone_curve(curve.shoulder_input, 1.0F, curve) -
         hyperdr::render_tone_curve(curve.shoulder_input - h, 1.0F, curve)) / h;
    const float shoulder_right =
        (hyperdr::render_tone_curve(curve.shoulder_input + h, 1.0F, curve) -
         hyperdr::render_tone_curve(curve.shoulder_input, 1.0F, curve)) / h;
    require(std::abs(shoulder_left - shoulder_right) < 3.0e-3F, "shoulder join is not C1");

    for (int i = 0; i <= 1000; ++i) {
      const float x = curve.shoulder_input * static_cast<float>(i) / 1000.0F;
      require(hyperdr::render_tone_curve(x, 1.0F, curve) ==
                  hyperdr::render_tone_curve(x, 8.0F, curve),
              "SDR and HDR curves diverged below the knee");
    }
    check_curve(1.0F, curve);
    check_curve(8.0F, curve);

    auto non_monotonic = options;
    non_monotonic.toe_output_ratio = 0.25F;
    bool rejected = false;
    try {
      static_cast<void>(hyperdr::build_tone_curve(non_monotonic));
    } catch (const std::invalid_argument&) {
      rejected = true;
    }
    require(rejected, "a toe with a negative initial slope was accepted");

    hyperdr::FloatImage grayscale(2, 2, 1);
    rejected = false;
    try {
      static_cast<void>(hyperdr::compute_luminance_statistics(grayscale));
    } catch (const std::invalid_argument&) {
      rejected = true;
    }
    require(rejected, "scene statistics accepted a non-RGB image");
    std::cout << "tone curve tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "tone curve test failure: " << error.what() << '\n';
    return 1;
  }
}
