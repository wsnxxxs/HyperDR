#pragma once

// One resampling policy for every bounded-resolution path.
//
// The conversion preview (--preview-max-edge) and the thumbnail command used
// to disagree: the former halved repeatedly while the longest edge exceeded
// the bound, so a 3201 px request for 1600 px landed on 800 px -- up to a
// factor of two smaller than asked for -- while the latter halved only down to
// twice the bound and then resampled to the exact size. Both now call this.
//
// Staged area reduction low-passes large reductions. Every shrinking stage,
// including odd rasters and the final fractional ratio, integrates uniform
// output-pixel footprints. Enlarged axes use centre-aligned bilinear sampling.
// All operations run on linear values to preserve mean highlight energy;
// reducing after an OETF would darken bright detail.

#include "hyperdr/image/image.hpp"

#include <cstdint>

namespace hyperdr {

inline constexpr char kResampleConvention[] = "uniform-area-stages/linear-upscale-v2";

// Scales so the longest edge is exactly `max_edge`, preserving aspect ratio.
// `max_edge` of 0, or an image already within the bound, returns the source
// unchanged. Throws std::invalid_argument for a bound above 8192.
[[nodiscard]] FloatImage resample_to_max_edge(FloatImage source, std::uint32_t max_edge);

// Scales to an exact size. Used directly by callers that already know the
// target dimensions; `resample_to_max_edge` is implemented on top of it.
[[nodiscard]] FloatImage resample_to(FloatImage source, std::uint32_t width,
                                     std::uint32_t height);

}  // namespace hyperdr
