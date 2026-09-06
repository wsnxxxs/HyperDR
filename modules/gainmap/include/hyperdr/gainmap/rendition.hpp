#pragma once
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/look/color_lut.hpp"
namespace hyperdr {
// Packaging adapter. Only gain-map exports cross this boundary.
GainMapResult gain_map_from_renditions(PhotoRenditions images);
// Compatibility adapter for model/external maps that intrinsically predict gain.
PhotoRenditions renditions_from_gain_map(GainMapResult images, bool include_hdr = true);
// Model/external grading retains the map's full affine reconstruction contract.
PhotoRenditions render_graded_gain_map(GainMapResult& images,
    const ColorLutOptions& grade, bool include_hdr = true, const ColorLut* lut = nullptr);
}  // namespace hyperdr
