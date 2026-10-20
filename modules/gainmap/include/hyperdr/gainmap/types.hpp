#pragma once

// The gain-map rendition: an SDR base image, a one- or three-channel gain map, the
// ISO 21496-1 metadata that relates them, and the measurements a run reports.

#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/look/rendition.hpp"

#include <array>
#include <cstdint>
#include <optional>

namespace hyperdr {

struct GainMapResult {
  FloatImage base_linear;
  FloatImage gain_map;
  GainMapMetadata metadata;
  bool clamp_srgb{false};
  float exposure_ev{};
  float headroom_stops{};
  RenderStats stats;
  // Framed exports protect the zero-gain mat from JPEG ringing at photo edges.
  bool presentation_frame{false};
};

}  // namespace hyperdr
