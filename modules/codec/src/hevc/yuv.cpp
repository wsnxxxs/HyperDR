#include "hevc/hevc.hpp"

#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace hyperdr::codec::hevc {
namespace {

constexpr std::uint32_t kChromaSize = kTileSize / 2;

void check_depth(int bit_depth) {
  if (bit_depth != 8 && bit_depth != 10) {
    throw std::invalid_argument("HEVC tiles are 8- or 10-bit");
  }
}

unsigned read_sample(const std::vector<std::uint8_t>& plane, std::size_t index, int bit_depth) {
  if (bit_depth <= 8) return plane[index];
  const auto word = static_cast<unsigned>(plane[index * 2]) |
                    (static_cast<unsigned>(plane[index * 2 + 1]) << 8U);
  return word >> 6U;
}

void write_sample(std::vector<std::uint8_t>& plane, std::size_t index, int bit_depth,
                  unsigned code) {
  if (bit_depth <= 8) {
    plane[index] = static_cast<std::uint8_t>(code);
    return;
  }
  const unsigned word = code << 6U;  // P010: the code in the high ten bits
  plane[index * 2] = static_cast<std::uint8_t>(word & 0xFFU);
  plane[index * 2 + 1] = static_cast<std::uint8_t>(word >> 8U);
}

struct LumaWeights {
  float kr, kg, kb;
};

LumaWeights weights_for(int matrix) {
  switch (matrix) {
    case 1: return {0.2126F, 0.7152F, 0.0722F};   // BT.709
    case 9: return {0.2627F, 0.6780F, 0.0593F};   // BT.2020 non-constant luminance
    default: throw std::invalid_argument("unsupported HEVC matrix coefficients");
  }
}

// [0, 1], with NaN as 0 (std::clamp passes NaN through).
float unit(float value) {
  return value > 0.0F ? (value < 1.0F ? value : 1.0F) : 0.0F;
}

// Code for a full-range sample (H.273 equations 26-28): luma spans
// [0, 2^n - 1]; chroma is centred on 2^(n-1). `value01` is already code / max.
unsigned quantise(float value01, unsigned max_code, bool dither, std::uint32_t x,
                  std::uint32_t y, std::uint32_t channel) {
  value01 = unit(value01);
  if (dither) return static_cast<unsigned>(quantize_dithered(value01, max_code, x, y, channel));
  return static_cast<unsigned>(std::lround(value01 * static_cast<float>(max_code)));
}

void check_tile(const TileGrid& grid, std::size_t index, const YuvTile& tile) {
  if (index >= grid.count()) throw std::invalid_argument("HEVC tile index outside the grid");
  check_depth(tile.bit_depth);
  if (tile.luma.size() != static_cast<std::size_t>(kTileSize) * tile.luma_row_bytes() ||
      tile.chroma.size() != static_cast<std::size_t>(kChromaSize) * tile.chroma_row_bytes()) {
    throw std::invalid_argument("HEVC tile planes have the wrong size");
  }
}

}  // namespace

unsigned YuvTile::luma_at(std::uint32_t x, std::uint32_t y) const noexcept {
  return read_sample(luma, static_cast<std::size_t>(y) * kTileSize + x, bit_depth);
}

unsigned YuvTile::cb_at(std::uint32_t x, std::uint32_t y) const noexcept {
  return read_sample(chroma, (static_cast<std::size_t>(y) * kChromaSize + x) * 2, bit_depth);
}

unsigned YuvTile::cr_at(std::uint32_t x, std::uint32_t y) const noexcept {
  return read_sample(chroma, (static_cast<std::size_t>(y) * kChromaSize + x) * 2 + 1, bit_depth);
}

YuvTile make_tile(int bit_depth) {
  check_depth(bit_depth);
  YuvTile tile;
  tile.bit_depth = bit_depth;
  tile.luma.resize(static_cast<std::size_t>(kTileSize) * tile.luma_row_bytes());
  tile.chroma.resize(static_cast<std::size_t>(kChromaSize) * tile.chroma_row_bytes());
  return tile;
}

TileGrid tile_grid(std::uint32_t width, std::uint32_t height) {
  if (width == 0 || height == 0) throw std::invalid_argument("empty HEVC picture");
  return {width, height, (width + kTileSize - 1) / kTileSize,
          (height + kTileSize - 1) / kTileSize};
}

void rgb_tile(const TileGrid& grid, std::size_t index, const RgbRowReader& read, int matrix,
              bool dither, YuvTile& tile) {
  check_tile(grid, index, tile);
  const auto w = weights_for(matrix);
  const int bit_depth = tile.bit_depth;
  const unsigned max_code = (1U << static_cast<unsigned>(bit_depth)) - 1U;
  const float chroma_offset = static_cast<float>(1U << static_cast<unsigned>(bit_depth - 1)) /
                              static_cast<float>(max_code);
  const float cb_scale = 1.0F / (2.0F * (1.0F - w.kb));
  const float cr_scale = 1.0F / (2.0F * (1.0F - w.kr));

  const std::uint32_t x0 = static_cast<std::uint32_t>(index % grid.columns) * kTileSize;
  const std::uint32_t y0 = static_cast<std::uint32_t>(index / grid.columns) * kTileSize;
  // Columns of the picture inside this tile; the rest repeat the last of them.
  const std::uint32_t inside = std::min(kTileSize, grid.width - x0);

  // One job per pair of rows: the pair shares a chroma row, and pairs write
  // disjoint rows of the tile, so the output does not depend on the workers.
  parallel_for_rows(kChromaSize, [&](const std::uint32_t pair) {
    std::vector<float> rgb(static_cast<std::size_t>(inside) * 3);
    std::vector<float> cb(kTileSize), cr(kTileSize);
    for (std::uint32_t half = 0; half < 2; ++half) {
      const std::uint32_t ty = pair * 2 + half;
      const std::uint32_t y = y0 + ty;
      read(std::min(y, grid.height - 1), x0, inside, rgb.data());
      for (std::uint32_t tx = 0; tx < kTileSize; ++tx) {
        const float* px = rgb.data() + static_cast<std::size_t>(std::min(tx, inside - 1)) * 3;
        const float r = unit(px[0]);
        const float g = unit(px[1]);
        const float b = unit(px[2]);
        const float luma = w.kr * r + w.kg * g + w.kb * b;
        const float pb = (b - luma) * cb_scale;
        const float pr = (r - luma) * cr_scale;
        cb[tx] = half == 0 ? pb : cb[tx] + pb;
        cr[tx] = half == 0 ? pr : cr[tx] + pr;
        write_sample(tile.luma, static_cast<std::size_t>(ty) * kTileSize + tx, bit_depth,
                     quantise(luma, max_code, dither, x0 + tx, y, 0));
      }
    }
    for (std::uint32_t cx = 0; cx < kChromaSize; ++cx) {
      const float mean_cb = (cb[cx * 2] + cb[cx * 2 + 1]) * 0.25F;
      const float mean_cr = (cr[cx * 2] + cr[cx * 2 + 1]) * 0.25F;
      const std::size_t at = (static_cast<std::size_t>(pair) * kChromaSize + cx) * 2;
      const std::uint32_t px = x0 / 2 + cx;
      const std::uint32_t py = y0 / 2 + pair;
      write_sample(tile.chroma, at, bit_depth,
                   quantise(mean_cb + chroma_offset, max_code, dither, px, py, 1));
      write_sample(tile.chroma, at + 1, bit_depth,
                   quantise(mean_cr + chroma_offset, max_code, dither, px, py, 2));
    }
  });
}

void luma_tile(const TileGrid& grid, std::size_t index, const LumaRowReader& read,
               YuvTile& tile) {
  check_tile(grid, index, tile);
  const int bit_depth = tile.bit_depth;
  const unsigned max_code = (1U << static_cast<unsigned>(bit_depth)) - 1U;
  const unsigned neutral = 1U << static_cast<unsigned>(bit_depth - 1);
  const std::uint32_t x0 = static_cast<std::uint32_t>(index % grid.columns) * kTileSize;
  const std::uint32_t y0 = static_cast<std::uint32_t>(index / grid.columns) * kTileSize;
  const std::uint32_t inside = std::min(kTileSize, grid.width - x0);

  for (std::size_t s = 0; s < static_cast<std::size_t>(kChromaSize) * kChromaSize * 2; ++s) {
    write_sample(tile.chroma, s, bit_depth, neutral);
  }
  parallel_for_rows(kTileSize, [&](const std::uint32_t ty) {
    std::vector<float> row(inside);
    read(std::min(y0 + ty, grid.height - 1), x0, inside, row.data());
    for (std::uint32_t tx = 0; tx < kTileSize; ++tx) {
      write_sample(tile.luma, static_cast<std::size_t>(ty) * kTileSize + tx, bit_depth,
                   quantise(row[std::min(tx, inside - 1)], max_code, false, 0, 0, 0));
    }
  });
}

std::vector<YuvTile> tiles_from_rgb(std::uint32_t width, std::uint32_t height,
                                    const RgbRowReader& read, int matrix, int bit_depth,
                                    bool dither) {
  const auto grid = tile_grid(width, height);
  std::vector<YuvTile> tiles;
  tiles.reserve(grid.count());
  for (std::size_t i = 0; i < grid.count(); ++i) {
    tiles.push_back(make_tile(bit_depth));
    rgb_tile(grid, i, read, matrix, dither, tiles.back());
  }
  return tiles;
}

std::vector<YuvTile> tiles_from_luma(std::uint32_t width, std::uint32_t height,
                                     const LumaRowReader& read, int bit_depth) {
  const auto grid = tile_grid(width, height);
  std::vector<YuvTile> tiles;
  tiles.reserve(grid.count());
  for (std::size_t i = 0; i < grid.count(); ++i) {
    tiles.push_back(make_tile(bit_depth));
    luma_tile(grid, i, read, tiles.back());
  }
  return tiles;
}

}  // namespace hyperdr::codec::hevc
