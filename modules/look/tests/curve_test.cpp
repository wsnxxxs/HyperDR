// The exported curve is what the browser panel renders its live preview from,
// so its shape has to hold the same guarantees the encoder relies on: no gain
// below the shoulder, monotonic expansion above it, and a peak that matches
// the requested headroom.

#include "hyperdr/look/curve.hpp"

#include <cmath>
#include <cstddef>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::LookOptions look_with(float shoulder_start) {
  hyperdr::LookOptions look;
  look.shoulder_start = shoulder_start;
  return look;
}

void check_shape() {
  const auto curve = hyperdr::build_look_curve(look_with(0.48F), 3.0F, 257);
  require(curve.sdr.size() == 257 && curve.gain_stops.size() == 257, "sample count");
  require(curve.sdr.front() == 0.0F && curve.sdr.back() == 1.0F, "uniform SDR grid");
  require(std::abs(curve.headroom_stops - 3.0F) < 1.0e-5F, "requested headroom");

  float previous = -1.0F;
  for (std::size_t i = 0; i < curve.sdr.size(); ++i) {
    const float gain = curve.gain_stops[i];
    require(std::isfinite(gain), "curve produced a non-finite gain");
    require(gain >= -1.0e-6F, "gain must never be negative");
    require(gain <= curve.headroom_stops + 1.0e-3F,
            "gain must not exceed the requested headroom");
    require(gain + 1.0e-5F >= previous, "gain must be monotonic in SDR level");
    previous = gain;
    // The shoulder invariant: SDR and HDR are identical below the knee, so no
    // gain may appear there. This is the property that keeps shadows clean.
    if (curve.sdr[i] < curve.shoulder_output - 0.01F) {
      require(gain < 1.0e-4F, "gain must be zero below the shoulder");
    }
  }
  require(curve.gain_stops.back() > curve.headroom_stops * 0.5F,
          "the brightest sample should use a meaningful share of the headroom");
}

// The scene column must invert the SDR curve: rendering it should reproduce
// the SDR level it is paired with.
void check_scene_inversion() {
  const auto look = look_with(0.5F);
  const auto curve = hyperdr::build_look_curve(look, 2.0F, 65);
  for (std::size_t i = 0; i + 1 < curve.sdr.size(); ++i) {
    const float rendered = hyperdr::render_tone_curve(curve.scene[i], 1.0F, curve.curve);
    require(std::abs(rendered - curve.sdr[i]) < 2.0e-3F,
            "the scene column must invert the SDR curve");
  }
}

void check_no_headroom_means_no_gain() {
  const auto curve = hyperdr::build_look_curve(look_with(0.48F), 0.0F, 33);
  for (const float gain : curve.gain_stops) {
    require(gain == 0.0F, "zero headroom must produce zero gain everywhere");
  }
}

void check_sample_bounds() {
  bool threw = false;
  try {
    static_cast<void>(hyperdr::build_look_curve(look_with(0.48F), 2.0F, 1));
  } catch (const std::invalid_argument&) {
    threw = true;
  }
  require(threw, "a sample count below two must be rejected");
}

// The neutral look has its own curve. Exporting the photographic one for it
// meant the panel previewed maths the neutral renderer never runs.
void check_neutral_curve_is_neutral() {
  hyperdr::LookOptions neutral;
  neutral.mode = hyperdr::LookMode::kNeutral;
  const auto curve = hyperdr::build_look_curve(neutral, 3.0F, 257);

  require(std::abs(curve.shoulder_output - hyperdr::kNeutralKnee) < 1.0e-6F,
          "the neutral curve's shoulder is the neutral knee");

  const auto photographic = hyperdr::build_look_curve(hyperdr::LookOptions{}, 3.0F, 257);
  require(std::abs(photographic.shoulder_output - curve.shoulder_output) > 1.0e-3F,
          "the two looks must not export the same curve");

  // Below the knee the neutral base is the identity, so the sampled scene
  // luminance equals the SDR level exactly.
  for (std::size_t i = 0; i < curve.sdr.size(); ++i) {
    if (curve.sdr[i] > hyperdr::kNeutralKnee) break;
    require(std::abs(curve.scene[i] - curve.sdr[i]) < 1.0e-5F,
            "neutral is the identity below its knee");
  }

  // Above the knee it is the renderer's compression, reproduced here so the
  // test fails if either side changes alone.
  for (std::size_t i = 0; i < curve.sdr.size(); ++i) {
    const float level = curve.sdr[i];
    if (level <= hyperdr::kNeutralKnee || level > 0.99F) continue;
    const float u = (curve.scene[i] - hyperdr::kNeutralKnee) /
                    (1.0F - hyperdr::kNeutralKnee);
    const float rendered = hyperdr::kNeutralKnee +
                           (1.0F - hyperdr::kNeutralKnee) * u / (1.0F + u);
    require(std::abs(rendered - level) < 1.0e-4F,
            "the neutral curve must invert the neutral renderer's knee");
  }

  for (const float gain : curve.gain_stops) {
    require(gain >= -1.0e-6F && gain <= curve.headroom_stops + 1.0e-3F,
            "neutral gain stays within its own headroom");
  }
}

// The renderer clamps to three stops. A curve that reported four described a
// rendition the exporter would never produce.
void check_neutral_headroom_ceiling() {
  hyperdr::LookOptions neutral;
  neutral.mode = hyperdr::LookMode::kNeutral;
  const auto curve = hyperdr::build_look_curve(neutral, 4.0F, 65);
  require(std::abs(curve.headroom_stops - hyperdr::kNeutralHeadroomStops) < 1.0e-6F,
          "neutral curve headroom is capped at the renderer's ceiling");
  require(std::abs(curve.headroom_linear -
                   std::exp2(hyperdr::kNeutralHeadroomStops)) < 1.0e-4F,
          "linear headroom follows the cap");
}

}  // namespace

int main() {
  try {
    check_shape();
    check_scene_inversion();
    check_no_headroom_means_no_gain();
    check_sample_bounds();
    check_neutral_curve_is_neutral();
    check_neutral_headroom_ceiling();
  } catch (const std::exception& e) {
    std::cerr << "look_curve_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "look_curve_test passed\n";
  return 0;
}
