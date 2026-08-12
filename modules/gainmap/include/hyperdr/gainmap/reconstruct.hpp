#pragma once

// Applying a gain map to its base image.
//
// This is how the converter verifies its own output: the same arithmetic an
// Apple or Android display pipeline performs, at a chosen display headroom. If
// the numbers here do not reproduce the intended HDR rendition, neither will
// the device.

#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/image/image.hpp"

#include <cstdint>

namespace hyperdr {

// How much of the render the closing max(0, ...) had to invent. The display-
// domain protocol requires this per arm at every headroom, because a curve
// point where candidate and reference clamp at different rates is not a
// comparison between two renders, it is a comparison between two different
// amounts of clamping. Values counts channel samples; pixels counts pixels
// with at least one clamped channel, so one clamped channel and a wholly
// clamped pixel stay distinguishable instead of averaging into each other.
struct ReconstructionStats {
  std::uint64_t total_values{};
  std::uint64_t clamp_values{};
  std::uint64_t total_pixels{};
  std::uint64_t clamp_pixels{};
};

[[nodiscard]] FloatImage reconstruct_gain_map(
    const FloatImage& base, const FloatImage& gain,
    const GainMapMetadata& metadata, float display_headroom_stops,
    ReconstructionStats* stats = nullptr);

}  // namespace hyperdr
