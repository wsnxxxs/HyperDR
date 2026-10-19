#pragma once
#include <cstdint>

#include "hyperdr/foundation/progress.hpp"
namespace hyperdr {
// Shared by container admission and the codec allocation boundary. Keep both
// orientations explicit; an area-only limit would admit unsupported geometry.
inline constexpr std::uint64_t kRasterWidthLimit = 11656;
inline constexpr std::uint64_t kRasterHeightLimit = 8742;
inline constexpr std::uint64_t kRasterPixelLimit = kRasterWidthLimit * kRasterHeightLimit;
[[nodiscard]] inline bool raster_input_budget_ok(std::uint64_t width, std::uint64_t height) {
  const bool geometry = (width <= kRasterWidthLimit && height <= kRasterHeightLimit) ||
                        (height <= kRasterWidthLimit && width <= kRasterHeightLimit);
  if (!geometry || !width || !height || width > kRasterPixelLimit / height) return false;
  return !current_execution_config.memory_budget_bytes ||
         width * height <= current_execution_config.memory_budget_bytes / 15;
}
}  // namespace hyperdr
