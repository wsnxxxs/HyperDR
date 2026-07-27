#include "hyperdr/look/tone_curve.hpp"

#include "hyperdr/foundation/math.hpp"

#include <cmath>
#include <stdexcept>

namespace hyperdr {

ToneCurveParameters build_tone_curve(const LookOptions& options) {
  if (!(std::isfinite(options.toe_end) && std::isfinite(options.toe_output_ratio) &&
        std::isfinite(options.contrast) && std::isfinite(options.shoulder_start) &&
        options.toe_end > 0.0F && options.toe_output_ratio > 0.0F &&
        options.toe_output_ratio < 1.0F && options.contrast > 0.0F &&
        options.shoulder_start > 0.0F && options.shoulder_start < 1.0F)) {
    throw std::invalid_argument("invalid photographic tone-curve parameters");
  }
  ToneCurveParameters curve;
  curve.toe_end = options.toe_end;
  curve.toe_output = options.toe_output_ratio * options.contrast * curve.toe_end;
  curve.contrast = options.contrast;
  curve.shoulder_output = options.shoulder_start;
  curve.shoulder_input = curve.toe_end +
      (curve.shoulder_output - curve.toe_output) / curve.contrast;
  if (!(curve.toe_output > 0.0F && curve.toe_output < curve.shoulder_output &&
        curve.shoulder_input > curve.toe_end && std::isfinite(curve.shoulder_input))) {
    throw std::invalid_argument("photographic tone curve is not monotonic");
  }
  return curve;
}

float render_tone_curve(float scene_luminance, float peak,
                        const ToneCurveParameters& curve) {
  if (!(std::isfinite(peak) && peak >= 1.0F &&
        peak - curve.shoulder_output > kEpsilon)) {
    throw std::invalid_argument("invalid photographic tone-curve peak");
  }
  if (std::isnan(scene_luminance) || scene_luminance <= 0.0F) return 0.0F;
  if (!std::isfinite(scene_luminance)) return peak;
  if (scene_luminance <= curve.toe_end) {
    const float a = (3.0F * curve.toe_output - curve.contrast * curve.toe_end) /
                    (curve.toe_end * curve.toe_end);
    const float b = (curve.contrast * curve.toe_end - 2.0F * curve.toe_output) /
                    (curve.toe_end * curve.toe_end * curve.toe_end);
    return std::max(0.0F, a * scene_luminance * scene_luminance +
                              b * scene_luminance * scene_luminance * scene_luminance);
  }
  if (scene_luminance <= curve.shoulder_input) {
    return curve.toe_output + curve.contrast * (scene_luminance - curve.toe_end);
  }
  const float exponent = -curve.contrast * (scene_luminance - curve.shoulder_input) /
                         (peak - curve.shoulder_output);
  return peak - (peak - curve.shoulder_output) * std::exp(std::max(exponent, -80.0F));
}

}  // namespace hyperdr
