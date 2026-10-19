#pragma once

// When an AVIF canvas has to be written as a grid of independently coded cells.
//
// libaom refuses to allocate a source frame larger than 1 GiB (its 8 GiB
// allocation cap divided by REF_FRAMES), whatever the memory of the host: a
// 10200x18134 10-bit 4:4:4 canvas fails with "Failed to allocate lag buffers".
// Splitting the canvas into cells bounds every libaom frame by the cell, and a
// grid is what libavif, ImageIO and Chromium all decode. Canvases below the
// limit keep the single-item layout, so their bytes do not change.

#include <algorithm>
#include <cstdint>

namespace hyperdr {

struct AvifGridLayout {
  std::uint32_t columns{1}, rows{1};
  // The first cell's size; the last column and row hold the remainder.
  std::uint32_t cell_width{}, cell_height{};
  [[nodiscard]] bool is_grid() const noexcept { return columns * rows > 1; }
};

// libaom's source frame for a 10-bit 4:4:4 image: 16-bit samples in three
// planes, each with the encoder's 160-pixel border, plus the 8-bit pyramid the
// non-realtime encoder allocates and counts toward the same cap. Measured to
// agree with the libaom limit on both sides (11800x11800 encodes, 12000x12000
// does not).
[[nodiscard]] constexpr std::uint64_t avif_single_frame_bytes(std::uint32_t width,
                                                              std::uint32_t height) noexcept {
  constexpr std::uint64_t border = 160;
  const auto aligned_width = (std::uint64_t(width) + 7) & ~std::uint64_t(7);
  const auto aligned_height = (std::uint64_t(height) + 7) & ~std::uint64_t(7);
  const auto stride = (aligned_width + 2 * border + 31) & ~std::uint64_t(31);
  const auto plane = (aligned_height + 2 * border) * stride;
  const auto pyramid = std::uint64_t(width) * height / 3 * 4 + (1ULL << 20);
  return 2 * 3 * plane + pyramid;
}

// libaom's cap, and the share of it a single item may use. The margin covers
// allocator and build differences; the cost is a grid for a few canvases
// between 126 and 139 MP that would just fit.
inline constexpr std::uint64_t kAvifLibaomFrameLimit = 1ULL << 30;
inline constexpr std::uint64_t kAvifSingleFrameBudget = kAvifLibaomFrameLimit / 10 * 9;
// Longest cell side, so each cell is a modest independent encode (4096x4096 is
// a 117 MB frame). libavif allows up to 256x256 cells.
inline constexpr std::uint32_t kAvifMaxCellSide = 4096;

[[nodiscard]] constexpr AvifGridLayout avif_grid_layout(std::uint32_t width,
                                                        std::uint32_t height) noexcept {
  AvifGridLayout layout{1, 1, width, height};
  if (avif_single_frame_bytes(width, height) <= kAvifSingleFrameBudget) return layout;
  // Balanced cells: the remainder in the last column or row is never a sliver.
  layout.columns = std::clamp<std::uint32_t>((width + kAvifMaxCellSide - 1) / kAvifMaxCellSide, 1, 256);
  layout.rows = std::clamp<std::uint32_t>((height + kAvifMaxCellSide - 1) / kAvifMaxCellSide, 1, 256);
  layout.cell_width = (width + layout.columns - 1) / layout.columns;
  layout.cell_height = (height + layout.rows - 1) / layout.rows;
  return layout;
}

}  // namespace hyperdr
