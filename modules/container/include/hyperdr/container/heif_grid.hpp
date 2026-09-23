#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace hyperdr {

// Each tile is a standalone, single-primary hvc1 HEIF produced by libheif.
// Tiles are supplied in row-major order, with no Exif or XMP items.
struct EncodedHeifGrid {
  std::uint32_t width{}, height{}, columns{}, rows{};
  std::vector<std::vector<std::uint8_t>> tiles;
};

// Assemble one or two logical images. A one-tile image stays hvc1; a multi-tile
// image becomes a grid with hidden hvc1 leaves. Metadata belongs to the primary
// logical image. Adaptive HDR supplies [gain, base] with primary_index == 1.
[[nodiscard]] std::vector<std::uint8_t> assemble_heif_grids(
    const std::vector<EncodedHeifGrid>& images, std::size_t primary_index,
    const std::vector<std::uint8_t>& exif, const std::string& xmp);

}  // namespace hyperdr
