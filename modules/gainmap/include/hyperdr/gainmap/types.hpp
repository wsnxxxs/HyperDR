#pragma once

// The gain-map rendition: an SDR base image, a single-channel gain map, the
// ISO 21496-1 metadata that relates them, and the measurements a run reports.

#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/look/rendition.hpp"

#include <array>
#include <cstdint>
#include <optional>

namespace hyperdr {

using GainMapOptions = RenderOptions;

// Validates the renderer's own controls, then the look's, before any RAW decode
// or image allocation happens: a rejected setting should cost nothing.
void validate_gain_map_options(const GainMapOptions& options);

// The headroom the exported curve represents. Automatic headroom is content
// dependent, so a curve built without an image uses the configured ceiling.
[[nodiscard]] float nominal_headroom_stops(const GainMapOptions& options);

struct GainMapResult {
  FloatImage base_linear;
  FloatImage gain_map;
  GainMapMetadata metadata;
  bool clamp_srgb{false};
  float exposure_ev{};
  float headroom_stops{};
  RenderStats stats;
};

}  // namespace hyperdr
