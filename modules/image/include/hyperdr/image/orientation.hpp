#pragma once

// Normalising Exif orientation into the pixels.
//
// Orientation is a rotation the decoder is expected to apply, not a property
// of the file's own geometry: a phone stores landscape pixels and a tag saying
// "rotate 90". Carrying the tag downstream would mean every later stage --
// resampling, the gain grid, the encoder, the preview, the report's width and
// height -- has to agree about whether it applies. Applying it once at decode
// and declaring orientation 1 afterwards means none of them has to know.

#include "hyperdr/image/image.hpp"

#include <cstdint>

namespace hyperdr {

// True for the four orientations that exchange the two axes (5, 6, 7, 8), so a
// caller can predict the output geometry before transforming.
[[nodiscard]] bool exif_orientation_transposes(std::uint16_t orientation);

// Returns the image with `orientation` applied, so the result is orientation 1.
// Orientation 1 and any value outside [1, 8] are returned unchanged: an
// unusable tag must not silently rotate the photograph.
[[nodiscard]] FloatImage apply_exif_orientation(FloatImage image,
                                                std::uint16_t orientation);

}  // namespace hyperdr
