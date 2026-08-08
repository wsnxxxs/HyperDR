#include "hyperdr/look/curve.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace hyperdr {
namespace {

// The SDR curve asymptotes to 1 without reaching it, so the sampling grid is
// inverted up to a level just below white and the last value is held for 1.0.
constexpr float kHighestInvertibleSdr = 0.9995F;

float invert_sdr(float target, const ToneCurveParameters& curve) {
  if (target <= 0.0F) return 0.0F;
  // The curve is monotonically increasing, so a bisection converges without
  // needing a closed-form inverse for each of the three segments.
  float low = 0.0F;
  float high = 1.0F;
  while (render_tone_curve(high, 1.0F, curve) < target && high < 1.0e6F) high *= 2.0F;
  for (int iteration = 0; iteration < 64; ++iteration) {
    const float middle = 0.5F * (low + high);
    if (render_tone_curve(middle, 1.0F, curve) < target) low = middle;
    else high = middle;
  }
  return 0.5F * (low + high);
}

}  // namespace

LookCurve build_look_curve(const LookOptions& look, float headroom_stops,
                           unsigned samples) {
  if (samples < 2 || samples > 4096) {
    throw std::invalid_argument("curve sample count must be in [2,4096]");
  }
  validate_look_options(look);

  LookCurve result;
  result.curve = build_tone_curve(look);
  result.shoulder_output = result.curve.shoulder_output;
  result.headroom_stops = std::max(0.0F, headroom_stops);
  result.headroom_linear = std::exp2(result.headroom_stops);

  // render_tone_curve rejects a peak that does not clear the shoulder, which
  // is exactly the degenerate case where no expansion exists at all.
  const bool expandable =
      result.headroom_linear > result.curve.shoulder_output + 1.0e-6F &&
      result.headroom_linear > 1.0F;

  result.sdr.resize(samples);
  result.scene.resize(samples);
  result.gain_stops.resize(samples);
  for (unsigned i = 0; i < samples; ++i) {
    const float level = static_cast<float>(i) / static_cast<float>(samples - 1);
    result.sdr[i] = level;
    const float invertible = std::min(level, kHighestInvertibleSdr);
    const float scene = invert_sdr(invertible, result.curve);
    result.scene[i] = scene;
    if (!expandable || level <= 0.0F) {
      result.gain_stops[i] = 0.0F;
      continue;
    }
    const float hdr = render_tone_curve(scene, result.headroom_linear, result.curve);
    const float base = std::max(render_tone_curve(scene, 1.0F, result.curve), 1.0e-6F);
    result.gain_stops[i] = std::max(0.0F, std::log2(std::max(hdr, base) / base));
  }
  return result;
}

}  // namespace hyperdr
