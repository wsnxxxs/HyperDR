#pragma once
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/look/color_lut.hpp"
namespace hyperdr {
// Packaging adapter. Generic ISO output can preserve independently graded
// endpoints with RGB gain. Adaptive HEIC keeps its single-channel profile.
GainMapResult gain_map_from_renditions(PhotoRenditions images,
    GainMapWriterProfile profile = GainMapWriterProfile::apple_strict);
// Compatibility adapter for model/external maps that intrinsically predict gain.
PhotoRenditions renditions_from_gain_map(GainMapResult images, bool include_hdr = true);
// Model/external grading retains the map's full affine reconstruction contract.
PhotoRenditions render_graded_gain_map(GainMapResult& images,
    const ColorLutOptions& grade, bool include_hdr = true, const ColorLut* lut = nullptr);
}  // namespace hyperdr
