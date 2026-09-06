#pragma once

#include "hyperdr/look/grid.hpp"
#include "hyperdr/look/options.hpp"

#include <vector>

namespace hyperdr {

struct LocalGain {
  std::vector<float> stops;
  std::vector<float> local_average;
  float weight_mean{1.0F};
  float weight_p95{1.0F};
};

// The global gain is already averaged from per-pixel requests. Environment
// analysis uses cell luminance without discarding that highlight evidence.
LocalGain weight_local_highlights(const std::vector<float>& global_gain,
                                 const std::vector<float>& scene_luma,
                                 const std::vector<float>& sdr_guide,
                                 GainGridDimensions dimensions,
                                 const CaptureMetadata& capture,
                                 const LookOptions& look);

}  // namespace hyperdr
