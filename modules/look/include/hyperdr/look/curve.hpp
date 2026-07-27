#pragma once

// The exporter's global tone curve, sampled as data.
//
// The browser panel used to reimplement the highlight-expansion maths twice --
// once in JavaScript for the canvas preview and once in WGSL for the WebGPU
// path -- alongside the C++ renderer that actually writes the file. Three hand-
// maintained copies of the same curve drift, and "the preview does not match
// the export" is the worst failure mode this tool has. `HyperDR curve --json`
// emits this sampling so both front-end paths interpolate the real curve
// instead of approximating it.
//
// Local highlight weighting is deliberately not represented: it is spatial, so
// no one-dimensional table can carry it. The report's `rendered_peak` remains
// the authority for what the local stage actually did.

#include "hyperdr/look/options.hpp"
#include "hyperdr/look/tone_curve.hpp"

#include <vector>

namespace hyperdr {

struct LookCurve {
  // Uniform grid over SDR output level, `sdr[i] == i / (samples - 1)`.
  std::vector<float> sdr;
  // Scene luminance that renders to `sdr[i]`, and the HDR rendition of that
  // same scene luminance expressed as gain in stops over the SDR base.
  std::vector<float> scene;
  std::vector<float> gain_stops;
  ToneCurveParameters curve{};
  float headroom_stops{0.0F};
  float headroom_linear{1.0F};
  // Linear SDR level where HDR-only expansion begins; below it the two
  // renditions are identical by construction.
  float shoulder_output{0.0F};
};

// `headroom_stops` is the expansion this curve represents. Automatic headroom
// is content dependent and therefore not a property of the curve, so callers
// pass the configured ceiling: the strongest expansion the look can request and
// the honest upper bound for a preview.
[[nodiscard]] LookCurve build_look_curve(const LookOptions& look,
                                         float headroom_stops,
                                         unsigned samples = 257);

}  // namespace hyperdr
