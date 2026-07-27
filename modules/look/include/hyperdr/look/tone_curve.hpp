#pragma once

// The global tone curve: a quadratic-cubic toe, a straight middle at the
// requested contrast, and an exponential shoulder that lands on the requested
// peak. `peak` is the only difference between the SDR and HDR renditions, which
// is what makes the two identical below the shoulder by construction rather
// than by convention.

#include "hyperdr/look/options.hpp"

namespace hyperdr {

struct ToneCurveParameters {
  float toe_end{};
  float toe_output{};
  float contrast{};
  float shoulder_input{};
  float shoulder_output{};
};

[[nodiscard]] ToneCurveParameters build_tone_curve(const LookOptions& options);

// `peak` is the linear output ceiling: 1 for the SDR base, the headroom
// multiplier for the HDR rendition. Throws for a peak that does not clear the
// shoulder, which is the degenerate case with no expansion range at all.
[[nodiscard]] float render_tone_curve(float scene_luminance, float peak,
                                      const ToneCurveParameters& curve);

}  // namespace hyperdr
