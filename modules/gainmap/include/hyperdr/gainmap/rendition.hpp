#pragma once
#include "hyperdr/gainmap/types.hpp"
namespace hyperdr {
// Packaging adapter. Only gain-map exports cross this boundary.
GainMapResult gain_map_from_renditions(PhotoRenditions images);
// Compatibility adapter for model/external maps that intrinsically predict gain.
PhotoRenditions renditions_from_gain_map(GainMapResult images, bool include_hdr = true);
}  // namespace hyperdr
