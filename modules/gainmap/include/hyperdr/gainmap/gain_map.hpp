#pragma once

// Rendering a linear Display-P3 image into an SDR base plus a gain map.
//
// One renderer implements this: the photographic perceptual pipeline. Nothing
// downstream -- encoder, verifier, or report -- depends on which look produced
// a result, which is what let the earlier `kNeutral` renderer be removed
// without touching them.

#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/grid.hpp"

namespace hyperdr {

// Source-only measurements, reusable across exposure and look changes. The
// caller owns their association with the decoded source and its resolution.
struct PhotographicAnalysis {
  SceneStatistics scene_stats;
  GainGridDimensions dimensions;
  std::vector<float> cell_mean;
  std::vector<float> cell_peak;
};

[[nodiscard]] PhotographicAnalysis analyze_photographic_source(const FloatImage& source);

// `input` is what the decoder produced, and it selects the renderer: only a
// scene-referred input gets the photographic curve and its automatic exposure.
// It defaults to scene-referred so that the renderer's own tests, which build
// synthetic sensor-linear images, keep describing exactly what they mean.
[[nodiscard]] GainMapResult make_gain_map(const FloatImage& linear_p3,
                                          const GainMapOptions& options,
                                          const CaptureMetadata& capture = {},
                                          const InputDescription& input = {},
                                          const PhotographicAnalysis* analysis = nullptr,
    GainMapPreparation* preparation = nullptr);

// Exposed separately from make_gain_map for callers and tests that want the
// renderer without the shared input measurement around it.
[[nodiscard]] GainMapResult make_photographic_gain_map(
    const FloatImage& linear_p3, const GainMapOptions& options,
    const CaptureMetadata& capture,
    const PhotographicAnalysis* analysis = nullptr,
    GainMapPreparation* preparation = nullptr);

// Selects the same content-aware exposure that the photographic renderer uses
// before it builds the gain map. Callers that need an exposure anchor without
// the user's creative bias should pass options.exposure_bias_ev = 0.
[[nodiscard]] float photographic_exposure_ev(
    const FloatImage& linear_p3, const GainMapOptions& options,
    const CaptureMetadata& capture = {});

}  // namespace hyperdr
