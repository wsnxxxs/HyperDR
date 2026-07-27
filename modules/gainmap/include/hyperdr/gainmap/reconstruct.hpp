#pragma once

// Applying a gain map to its base image.
//
// This is how the converter verifies its own output: the same arithmetic an
// Apple or Android display pipeline performs, at a chosen display headroom. If
// the numbers here do not reproduce the intended HDR rendition, neither will
// the device.

#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/image/image.hpp"

namespace hyperdr {

[[nodiscard]] FloatImage reconstruct_gain_map(const FloatImage& base,
                                              const FloatImage& gain,
                                              const GainMapMetadata& metadata,
                                              float display_headroom_stops);

}  // namespace hyperdr
