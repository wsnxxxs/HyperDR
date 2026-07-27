#include "hyperdr/look/analysis.hpp"

#include "hyperdr/foundation/math.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

namespace hyperdr {

std::optional<float> estimate_ev100(const CaptureMetadata& capture) {
  if (!capture.iso || !capture.exposure_time_seconds || !capture.aperture_f_number) {
    return std::nullopt;
  }
  const float iso = *capture.iso;
  const float time = *capture.exposure_time_seconds;
  const float aperture = *capture.aperture_f_number;
  if (!(std::isfinite(iso) && std::isfinite(time) && std::isfinite(aperture) &&
        iso > 0.0F && time > 0.0F && aperture > 0.0F)) {
    return std::nullopt;
  }
  const float ev100 = std::log2((aperture * aperture) / time) -
                      std::log2(iso / 100.0F);
  return std::isfinite(ev100) ? std::optional<float>(ev100) : std::nullopt;
}

float compute_target_middle_gray(std::optional<float> ev100) {
  if (!ev100) return 0.18F;
  return std::lerp(0.10F, 0.18F, smoothstep(5.0F, 10.0F, *ev100));
}

float highlight_limited_exposure(float p995, float peak,
                                 const ToneCurveParameters& curve) {
  if (!(p995 > 0.0F && peak > curve.shoulder_output + kEpsilon)) {
    return std::numeric_limits<float>::infinity();
  }
  const float target = peak * 0.95F;
  if (!(target > curve.shoulder_output && target < peak)) {
    return std::numeric_limits<float>::infinity();
  }
  const float numerator = peak - target;
  const float denominator = peak - curve.shoulder_output;
  const float scene_limit = curve.shoulder_input -
      (denominator / curve.contrast) * std::log(numerator / denominator);
  if (!(std::isfinite(scene_limit) && scene_limit > 0.0F)) {
    return std::numeric_limits<float>::infinity();
  }
  return std::log2(scene_limit / p995);
}

}  // namespace hyperdr
