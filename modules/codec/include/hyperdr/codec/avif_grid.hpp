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

// The size of libaom's source frame for the one configuration encode_avif
// writes: 10-bit 4:4:4, no alpha, all-intra (what libavif selects for a single
// image). Three 16-bit planes, plus the 8-bit pyramid the encoder allocates and
// counts toward the same cap. The 160-pixel border is deliberately larger than
// the all-intra border libaom really uses (64): the model is a little
// conservative, and the measured limit sits between 11800x11800 (encodes) and
// 12000x12000 (does not), where the 160 model reads 0.995 and 1.028 of the cap
// (a 64-pixel border reads 0.970 and 1.002). It would have to be revisited for
// any other depth, chroma format or alpha, so encode_avif static_asserts them.
inline constexpr int kAvifFrameBitDepth = 10;
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
// a 117 MB frame). libavif allows up to 256x256 cells. Cells are a multiple of
// 64 (MIAF recommends it for tile sizes); libavif pads the last column and row
// up to the cell size and the grid's output size crops them again.
inline constexpr std::uint32_t kAvifMaxCellSide = 4096;
inline constexpr std::uint32_t kAvifCellAlignment = 64;

// Pull-row exports stage 10-bit RGB and compressed AV1 samples on disk, and
// own only ONE cell / libaom context at a time. Mirror these in host estimates.
// Speed and quality are unchanged; there is no chroma or resolution reduction.
inline constexpr std::uint32_t kAvifRowMaxCellSide = 1024;
// Generic output verification also accepts grids from the older whole-image
// writer: its one-cell-at-a-time decode bound is 4096, NOT the row writer's
// 1024 encode bound. Do not use this compatibility ceiling to price row exports.
inline constexpr std::uint32_t kAvifVerifyMaxCellSide = kAvifMaxCellSide;
inline constexpr int kAvifRowMaxThreads = 2;
[[nodiscard]] constexpr AvifGridLayout avif_row_grid_layout(std::uint32_t width,
                                                           std::uint32_t height) noexcept {
  const auto columns = std::max(1U, (width + kAvifRowMaxCellSide - 1) / kAvifRowMaxCellSide);
  const auto rows = std::max(1U, (height + kAvifRowMaxCellSide - 1) / kAvifRowMaxCellSide);
  const auto side = [](std::uint32_t size, std::uint32_t count) {
    const auto balanced = (size + count - 1) / count;
    return (balanced + kAvifCellAlignment - 1) / kAvifCellAlignment * kAvifCellAlignment;
  };
  return {columns, rows, side(width, columns), side(height, rows)};
}

// What libavif will decode, whatever the encoder wrote (AVIF_DEFAULT_IMAGE_SIZE_LIMIT
// and the default dimension limit; neither can be raised). Past it a file is
// written but cannot be opened by libavif, Chromium or our own check.
inline constexpr std::uint64_t kAvifDecodeMaxPixels = 16384ULL * 16384ULL;
inline constexpr std::uint32_t kAvifDecodeMaxSide = 32768;
[[nodiscard]] constexpr bool avif_canvas_decodable(std::uint32_t width, std::uint32_t height) noexcept {
  return std::uint64_t(width) * height <= kAvifDecodeMaxPixels && width <= kAvifDecodeMaxSide &&
         height <= kAvifDecodeMaxSide;
}

[[nodiscard]] constexpr AvifGridLayout avif_grid_layout(std::uint32_t width,
                                                        std::uint32_t height) noexcept {
  AvifGridLayout layout{1, 1, width, height};
  if (avif_single_frame_bytes(width, height) <= kAvifSingleFrameBudget) return layout;
  // Balanced cells (the remainder in the last column or row is never a sliver),
  // rounded up to the alignment. Still at most the cap: it is a multiple of it.
  layout.columns = std::clamp<std::uint32_t>((width + kAvifMaxCellSide - 1) / kAvifMaxCellSide, 1, 256);
  layout.rows = std::clamp<std::uint32_t>((height + kAvifMaxCellSide - 1) / kAvifMaxCellSide, 1, 256);
  const auto aligned = [](std::uint32_t size, std::uint32_t count) {
    const auto balanced = (size + count - 1) / count;
    return (balanced + kAvifCellAlignment - 1) / kAvifCellAlignment * kAvifCellAlignment;
  };
  // An axis with one cell has nothing to align.
  layout.cell_width = layout.columns == 1 ? width : aligned(width, layout.columns);
  layout.cell_height = layout.rows == 1 ? height : aligned(height, layout.rows);
  return layout;
}

}  // namespace hyperdr
