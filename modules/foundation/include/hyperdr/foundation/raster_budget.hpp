#pragma once
#include <cstdint>

#include "hyperdr/foundation/progress.hpp"
namespace hyperdr {
// Shared by container admission and the codec allocation boundary. Keep both
// orientations explicit; an area-only limit would admit unsupported geometry.
inline constexpr std::uint64_t kRasterWidthLimit = 11656;
inline constexpr std::uint64_t kRasterHeightLimit = 8742;
inline constexpr std::uint64_t kRasterPixelLimit = kRasterWidthLimit * kRasterHeightLimit;
[[nodiscard]] inline bool raster_geometry_ok(std::uint64_t width, std::uint64_t height) {
  const bool geometry = (width <= kRasterWidthLimit && height <= kRasterHeightLimit) ||
                        (height <= kRasterWidthLimit && width <= kRasterHeightLimit);
  return geometry && width && height && width <= kRasterPixelLimit / height;
}
[[nodiscard]] inline bool raster_input_budget_ok(std::uint64_t width, std::uint64_t height) {
  if (!raster_geometry_ok(width, height)) return false;
  return !current_execution_config.memory_budget_bytes ||
         width * height <= current_execution_config.memory_budget_bytes / 15;
}
// Tiled images are decoded one coded picture at a time and reduced as they
// arrive, so their canvas is limited by structure (the reader's tile and
// memory-safety limits), not by the raster budget that sizes an output
// buffer. A coded picture (tile, or a single-picture image) still has to pass
// raster_geometry_ok; the output size is planned separately.
inline constexpr std::uint64_t kTiledEdgeLimit = 65535;
inline constexpr std::uint64_t kTiledPixelLimit = std::uint64_t(1) << 28;
[[nodiscard]] inline bool tiled_canvas_ok(std::uint64_t width, std::uint64_t height) {
  return width && height && width <= kTiledEdgeLimit && height <= kTiledEdgeLimit &&
         width <= kTiledPixelLimit / height;
}
}  // namespace hyperdr
