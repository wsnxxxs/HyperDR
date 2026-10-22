#pragma once
// Test-side view of a HEIC file through our own reader and VideoToolbox: the
// container facts come from read_heif, the samples from the HEVC pictures. No
// RGB conversion unless a test asks for one. (ImageIO is the independent
// reader; see tests/hevc/check_imageio.py.)
#include <array>
#include <cstdint>
#include <functional>
#include <stdexcept>
#include <vector>

#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"

namespace heif_native {
using Picture = hyperdr::codec::hevc::DecodedPicture;

// Calls visit(x0, y0, picture) for every coded picture of the plan, in tile
// order; (x0, y0) is the picture's origin on the plan's canvas.
inline void for_each_picture(
    const hyperdr::HeifFile& file, const hyperdr::HeifImagePlan& plan,
    const std::function<void(std::uint32_t, std::uint32_t, const Picture&)>& visit) {
  std::vector<std::uint8_t> joined;
  hyperdr::codec::hevc::decode_item(
      plan.config, plan.tiles.size(),
      [&](std::size_t i) -> std::span<const std::uint8_t> {
        const auto extents = plan.tiles[i].extents;
        if (extents.size() == 1) return file.bytes.subspan(extents[0].offset, extents[0].length);
        joined = file.item_bytes(plan.tiles[i].id);
        return joined;
      },
      [&](std::size_t i, Picture&& picture) {
        visit(std::uint32_t(i % plan.columns) * plan.tile_width,
              std::uint32_t(i / plan.columns) * plan.tile_height, picture);
      });
}

// Normalized encoded R'G'B' of one canvas pixel, converted the way the product
// converts (the plan's matrix and range, no transfer decoding).
inline std::array<float, 3> encoded_rgb(const hyperdr::HeifFile& file,
                                        const hyperdr::HeifImagePlan& plan,
                                        std::uint32_t x, std::uint32_t y) {
  namespace h = hyperdr::codec::hevc;
  std::array<float, 3> out{};
  bool found = false;
  const auto params = h::conversion_params(plan.config, plan.color ? &*plan.color : nullptr);
  for_each_picture(file, plan, [&](std::uint32_t x0, std::uint32_t y0, const Picture& picture) {
    if (x < x0 || y < y0 || x >= x0 + picture.width || y >= y0 + picture.height) return;
    h::yuv_to_rgb(picture, params, [&](unsigned row, std::span<const float> rgb) {
      if (row != y - y0) return;
      for (unsigned c = 0; c < 3; ++c) out[c] = rgb[3 * (x - x0) + c];
      found = true;
    });
  });
  if (!found) throw std::runtime_error("pixel is outside the decoded pictures");
  return out;
}
}  // namespace heif_native
