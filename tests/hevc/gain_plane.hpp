#pragma once
// E5 L1 product backends for absent ImageIO auxiliary Data (HEIC and RGB
// JPEG on macOS 27). Data, when present, retains precedence in the probe.
// P3b replaces the HEIC implementation and reruns these unchanged gates.
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/image.hpp"
#include "internal/decode_bytes.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include <libheif/heif.h>
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
  const auto refs = find_tmap_references(bytes);
  const auto checked = [](heif_error error) {
    if (error.code != heif_error_Ok) throw std::runtime_error(error.message);
  };
  std::unique_ptr<heif_context, decltype(&heif_context_free)> context(heif_context_alloc(), heif_context_free);
  if (!context) throw std::runtime_error("allocate gain-plane context");
  checked(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr));
  const auto handle = [&](unsigned id) {
    heif_image_handle* p = nullptr;
    checked(heif_context_get_image_handle(context.get(), id, &p));
    return std::unique_ptr<heif_image_handle, decltype(&heif_image_handle_release)>(p, heif_image_handle_release);
  };
  const auto base = handle(refs.base_id), gain = handle(refs.gain_id);
  heif_colorspace colorspace; heif_chroma chroma;
  checked(heif_image_handle_get_preferred_decoding_colorspace(base.get(), &colorspace, &chroma));
  if (chroma != heif_chroma_420 && chroma != heif_chroma_444)
    throw std::runtime_error("unsupported base chroma support in frame gate");
  heif_image* p = nullptr;
  checked(heif_decode_image(gain.get(), &p, heif_colorspace_undefined, heif_chroma_undefined, nullptr));
  std::unique_ptr<heif_image, decltype(&heif_image_release)> image(p, heif_image_release);
  const auto bits = heif_image_get_bits_per_pixel_range(image.get(), heif_channel_Y);
  if (bits != 8 && bits != 10) throw std::runtime_error("unsupported gain-plane depth");
  FloatImage codes(heif_image_get_width(image.get(), heif_channel_Y),
                   heif_image_get_height(image.get(), heif_channel_Y), 1);
  int stride = 0;
  const auto* data = heif_image_get_plane_readonly(image.get(), heif_channel_Y, &stride);
  if (!data) throw std::runtime_error("missing gain plane");
  const float maximum = (1U << bits)-1;
  for (unsigned y=0; y<codes.height; ++y) for (unsigned x=0; x<codes.width; ++x)
    codes.at(x,y,0) = (bits == 8 ? data[y*stride+x] :
        reinterpret_cast<const std::uint16_t*>(data+y*stride)[x]) / maximum;
  return {std::move(codes), unsigned(bits), chroma == heif_chroma_420 ? 3U : 0U, parse_tmap_payload(extract_tmap_payload(bytes))};
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
