#pragma once
// E5 L1 product backends for absent ImageIO auxiliary Data (HEIC and RGB
// JPEG on macOS 27). Data, when present, retains precedence in the probe.
// The HEIC reader is our own (read_heif plus VideoToolbox), not ImageIO's.
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/image.hpp"
#include "internal/decode_bytes.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include <memory>

namespace hyperdr::test {
struct GainPlane {
  FloatImage codes;
  unsigned bits;
  unsigned chroma_support;
  GainMapMetadata metadata;
};
inline GainPlane read_heic_gain_plane(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  const auto file = read_heif(bytes);
  const auto plans = file.resolve_gain_map(HeifCanvas::Tiled);
  if (!plans || !plans->metadata) throw std::runtime_error("HEIC lacks an ISO gain map");
  const auto& gain = plans->gain;
  const auto chroma = plans->base.config.chroma_format;
  if (chroma != 1 && chroma != 3) throw std::runtime_error("unsupported base chroma support in frame gate");
  const auto bits = gain.config.bit_depth;
  if (bits != 8 && bits != 10) throw std::runtime_error("unsupported gain-plane depth");
  FloatImage codes(gain.width, gain.height, 1);
  const float maximum = (1U << bits)-1;
  std::vector<std::uint8_t> joined;
  codec::hevc::decode_item(gain.config, gain.tiles.size(),
      [&](std::size_t i) -> std::span<const std::uint8_t> {
        const auto extents = gain.tiles[i].extents;
        if (extents.size() == 1) return file.bytes.subspan(extents[0].offset, extents[0].length);
        joined = file.item_bytes(gain.tiles[i].id);
        return joined;
      },
      [&](std::size_t i, codec::hevc::DecodedPicture&& picture) {
        const unsigned x0 = unsigned(i % gain.columns) * gain.tile_width, y0 = unsigned(i / gain.columns) * gain.tile_height;
        for (unsigned y = 0; y < picture.height && y0+y < codes.height; ++y)
          for (unsigned x = 0; x < picture.width && x0+x < codes.width; ++x)
            codes.at(x0+x, y0+y, 0) = picture.luma_at(x, y) / maximum;
      });
  return {std::move(codes), unsigned(bits), chroma == 1 ? 3U : 0U, *plans->metadata};
}
// Central replacement point for L1: use product raw readers only when
// ImageIO omits auxiliary Data. ImageIO independently checks the same file.
inline GainPlane read_gain_plane(const std::filesystem::path& path) {
  if (path.extension()==".heic") return read_heic_gain_plane(path);
  const auto bytes=read_binary_file(path);
  const auto parsed=parse_gain_map_jpeg_input(bytes);
  auto codes=codec::decode_jpeg_gain_bytes(
      {bytes.begin()+parsed.gain_offset,bytes.begin()+parsed.gain_offset+parsed.gain_size},
      gain_map_channel_count(parsed.metadata));
  // JPEG base chroma support is read independently from SOF by the Swift probe.
  return {std::move(codes),8,0,parsed.metadata};
}
} // namespace hyperdr::test
