#pragma once

// Scene measurement and the two decisions taken from it: how far to move
// exposure, and how much HDR headroom the picture actually earns.
//
// All three are separated from the renderer because they are where a
// photograph's character is decided, and because they are cheap to test
// directly: each one is a pure function of sampled statistics.

#include "hyperdr/look/options.hpp"
#include "hyperdr/look/tone_curve.hpp"
#include "hyperdr/image/image.hpp"

#include <cstdint>
#include <optional>
#include <vector>

namespace hyperdr {

struct SceneStatistics {
  // A strided sample of positive luminances, capped at roughly 200k entries so
  // the cost is independent of sensor resolution.
  std::vector<float> samples;
  // Geometric mean over the trimmed range, i.e. the scene's middle grey.
  float log_average{0.18F};
  float p995{0.0F};
  float p999{0.0F};
  float p9999{0.0F};
};

[[nodiscard]] SceneStatistics compute_luminance_statistics(const FloatImage& source);

// Exposure value at ISO 100 from the capture triple, or nullopt when any of the
// three fields is missing or implausible. A guessed EV is worse than none: it
// silently moves the whole rendition.
[[nodiscard]] std::optional<float> estimate_ev100(const CaptureMetadata& capture);

// Low-light captures are rendered darker on purpose; a night scene lifted to
// 0.18 middle grey stops looking like night.
[[nodiscard]] float compute_target_middle_gray(std::optional<float> ev100);

// The largest exposure, in stops, that still leaves the 99.5th percentile below
// the shoulder's useful ceiling. Infinity when no highlight constrains it.
[[nodiscard]] float highlight_limited_exposure(float p995, float peak,
                                               const ToneCurveParameters& curve);

// Headroom in stops, from percentile statistics and from connected bright
// regions in the gain grid. Isolated hot pixels are deliberately not enough:
// spending headroom on them costs highlight range everywhere else.
[[nodiscard]] float choose_headroom_stops(const SceneStatistics& stats,
                                          float exposure,
                                          const CaptureMetadata& capture,
                                          float maximum_stops,
                                          const std::vector<float>& cell_mean,
                                          const std::vector<float>& cell_peak,
                                          std::uint32_t width,
                                          std::uint32_t height, float pop);

}  // namespace hyperdr
