// Reading Ultra HDR JPEG/R as HDR input.
//
// Until now a JPEG/R was read through its backward-compatible SDR primary
// image, which throws away the entire point of the format: the gain map that
// carries the highlight information. Re-exporting such a file therefore lost
// real captured range at the input stage, before any look decision was made.
// libultrahdr can apply the gain map itself and hand back a linear HDR
// rendition, which is exactly the working space this pipeline wants.

#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/orientation.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "internal/decode_bytes.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/metadata.hpp"

#include <ultrahdr_api.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

struct DecoderDeleter {
  void operator()(uhdr_codec_private_t* decoder) const { uhdr_release_decoder(decoder); }
};

void check_uhdr(const uhdr_error_info_t& status, const char* operation) {
  if (status.error_code == UHDR_CODEC_OK) return;
  const std::string detail =
      status.has_detail != 0 ? std::string(status.detail) : std::string("unknown error");
  throw std::runtime_error(std::string(operation) + ": " + detail);
}

// IEEE 754 binary16 -> binary32. libultrahdr's linear output format is
// 64bppRGBAHalfFloat, and the conversion is short enough that pulling in a
// dependency for it would cost more than it saves.
constexpr float half_to_float(std::uint16_t half) {
  const std::uint32_t sign = static_cast<std::uint32_t>(half & 0x8000U) << 16U;
  const std::uint32_t exponent = (half >> 10U) & 0x1FU;
  const std::uint32_t mantissa = half & 0x3FFU;
  std::uint32_t bits = 0;
  if (exponent == 0) {
    if (mantissa != 0) {
      // Subnormal: normalise by shifting the mantissa until bit 10 is set.
      std::uint32_t shifted = mantissa;
      std::uint32_t adjust = 0;
      while ((shifted & 0x400U) == 0) {
        shifted <<= 1U;
        ++adjust;
      }
      shifted &= 0x3FFU;
      bits = ((127U - 14U - adjust) << 23U) | (shifted << 13U);
    }
  } else if (exponent == 0x1FU) {
    bits = 0x7F800000U | (mantissa << 13U);
  } else {
    bits = ((exponent + 127U - 15U) << 23U) | (mantissa << 13U);
  }
  bits |= sign;
  return std::bit_cast<float>(bits);
}

static_assert(half_to_float(0x0001U) == 0x1p-24F);
static_assert(half_to_float(0x03FFU) == 0x1.ff8p-15F);

std::array<float, 3> to_linear_p3(uhdr_color_gamut_t gamut,
                                 ColorGamut default_gamut,
                                 float r, float g, float b) {
  switch (gamut) {
    case UHDR_CG_DISPLAY_P3:
      return {std::max(0.0F, r), std::max(0.0F, g), std::max(0.0F, b)};
    case UHDR_CG_BT_2100:
      return rec2020_to_linear_p3(r, g, b);
    case UHDR_CG_UNSPECIFIED:
      switch (default_gamut) {
        case ColorGamut::kDisplayP3:
          return {std::max(0.0F, r), std::max(0.0F, g), std::max(0.0F, b)};
        case ColorGamut::kRec2020:
          return rec2020_to_linear_p3(r, g, b);
        case ColorGamut::kSrgb:
          break;
      }
      return rec709_to_linear_p3(r, g, b);
    case UHDR_CG_BT_709:
    default:
      return rec709_to_linear_p3(r, g, b);
  }
}

}  // namespace

namespace codec {

bool is_ultrahdr_bytes(const std::vector<std::uint8_t>& bytes) {
  if (bytes.size() < 4) return false;
  return is_uhdr_image(const_cast<std::uint8_t*>(bytes.data()),
                       static_cast<int>(bytes.size())) != 0;
}

}  // namespace codec

// Kept for the CLI and the codec tests, which hold a path rather than a buffer.
// `decode_image` no longer takes this route: it reads the file once and asks
// `codec::is_ultrahdr_bytes` about the bytes it already has.
bool is_ultrahdr_jpeg_file(const std::filesystem::path& path) {
  try {
    return codec::is_ultrahdr_bytes(read_binary_file(path));
  } catch (const std::exception&) {
    return false;
  }
}

// Decodes the gain-map-applied HDR rendition into linear Display P3 with SDR
// diffuse white at 1.0, which is the same normalisation the RAW path produces.
DecodedImage decode_ultrahdr(const std::filesystem::path& path) {
  return codec::decode_ultrahdr_bytes(read_binary_file(path),
                                      ColorGamut::kSrgb);
}

namespace codec {

DecodedImage decode_ultrahdr_bytes(const std::vector<std::uint8_t>& bytes,
                                   ColorGamut default_gamut) {
  if (bytes.empty()) throw std::runtime_error("Ultra HDR input is empty");
  auto authored_sdr = decode_jpeg_primary_bytes(bytes, default_gamut);

  std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> decoder(uhdr_create_decoder());
  if (!decoder) throw std::runtime_error("cannot create the Ultra HDR decoder");

  uhdr_compressed_image_t compressed{};
  // libultrahdr's struct is the same one its encoder fills, so the pointer is
  // non-const; the decoder only reads through it.
  compressed.data = const_cast<std::uint8_t*>(bytes.data());
  compressed.data_sz = bytes.size();
  compressed.capacity = bytes.size();
  compressed.cg = UHDR_CG_UNSPECIFIED;
  compressed.ct = UHDR_CT_UNSPECIFIED;
  compressed.range = UHDR_CR_UNSPECIFIED;
  check_uhdr(uhdr_dec_set_image(decoder.get(), &compressed), "Ultra HDR set image");
  check_uhdr(uhdr_dec_set_out_img_format(decoder.get(), UHDR_IMG_FMT_64bppRGBAHalfFloat),
             "Ultra HDR output format");
  check_uhdr(uhdr_dec_set_out_color_transfer(decoder.get(), UHDR_CT_LINEAR),
             "Ultra HDR output transfer");
  check_uhdr(uhdr_dec_probe(decoder.get()), "Ultra HDR probe");
  // The decoder defaults to an unbounded display boost and clamps it to the
  // gain map's hdr_capacity_max internally. Configuring it after probe is
  // invalid because probe advances libultrahdr out of its configurable state.
  check_uhdr(uhdr_decode(decoder.get()), "Ultra HDR decode");

  uhdr_raw_image_t* image = uhdr_get_decoded_image(decoder.get());
  if (image == nullptr || image->w == 0 || image->h == 0) {
    throw std::runtime_error("Ultra HDR decode produced no image");
  }
  if (image->fmt != UHDR_IMG_FMT_64bppRGBAHalfFloat) {
    throw std::runtime_error("Ultra HDR decode returned an unexpected pixel format");
  }
  const auto* packed =
      static_cast<const std::uint16_t*>(image->planes[UHDR_PLANE_PACKED]);
  if (packed == nullptr) throw std::runtime_error("Ultra HDR decode returned no plane");
  // libultrahdr reports stride in pixels for packed formats.
  const std::size_t stride = image->stride[UHDR_PLANE_PACKED] != 0
                                 ? image->stride[UHDR_PLANE_PACKED]
                                 : image->w;
  const auto gamut = image->cg;

  DecodedImage result;
  const char* source_primaries = gamut == UHDR_CG_DISPLAY_P3 ? "Display P3"
      : gamut == UHDR_CG_BT_2100 ? "Rec.2020"
      : gamut == UHDR_CG_BT_709 ? "Rec.709"
      : default_gamut == ColorGamut::kDisplayP3 ? "Display P3 (assumed)"
      : default_gamut == ColorGamut::kRec2020 ? "Rec.2020 (assumed)"
      : "Rec.709 (assumed)";
  result.source_color = {"Ultra HDR", source_primaries,
                         "Gain-map HDR reconstruction", "ultrahdr"};
  result.linear_p3 = FloatImage(image->w, image->h, 3);
  result.decode.sensor_width = image->w;
  result.decode.sensor_height = image->h;
  result.decode.target_width = image->w;
  result.decode.target_height = image->h;
  result.decode.decoded_width = image->w;
  result.decode.decoded_height = image->h;
  parallel_for_rows(image->h, [&](const std::uint32_t y) {
    const std::uint16_t* row = packed + static_cast<std::size_t>(y) * stride * 4U;
    for (std::uint32_t x = 0; x < image->w; ++x) {
      const float r = half_to_float(row[x * 4U + 0U]);
      const float g = half_to_float(row[x * 4U + 1U]);
      const float b = half_to_float(row[x * 4U + 2U]);
      const auto p3 = to_linear_p3(gamut, default_gamut,
                                   std::isfinite(r) ? r : 0.0F,
                                   std::isfinite(g) ? g : 0.0F,
                                   std::isfinite(b) ? b : 0.0F);
      result.linear_p3.at(x, y, 0) = p3[0];
      result.linear_p3.at(x, y, 1) = p3[1];
      result.linear_p3.at(x, y, 2) = p3[2];
    }
  });
  // The reconstructed alternate can exceed (or fall below) the metadata's
  // nominal capacity. Use its actual peak for the usable input range.
  result.hdr_headroom = measured_alternate_headroom(result.linear_p3);
  if (const uhdr_gainmap_metadata_t* gain =
          uhdr_dec_get_gainmap_metadata(decoder.get());
      gain != nullptr) {
    const auto* gain_image = uhdr_get_decoded_gainmap_image(decoder.get());
    result.gain_map.channels =
        gain_image && gain_image->fmt == UHDR_IMG_FMT_8bppYCbCr400 ? 1U : 3U;
    result.gain_map.base_headroom = std::max(1.0F, gain->hdr_capacity_min);
    result.gain_map.alternate_headroom = std::max(1.0F, gain->hdr_capacity_max);
    for (unsigned c = 0; c < 3; ++c) {
      result.gain_map.base_offset[c] = gain->offset_sdr[c];
      result.gain_map.alternate_offset[c] = gain->offset_hdr[c];
    }
  }
  result.domain = InputDomain::kDualRendition;

  result.metadata.orientation = 1;
  // libultrahdr exposes the authoritative Exif payload. The shared reader now
  // preserves the portable camera/capture fields while keeping unsafe maker
  // notes out, and orientation is normalised into pixels exactly once.
  if (const uhdr_mem_block_t* exif = uhdr_dec_get_exif(decoder.get());
      exif != nullptr && exif->data != nullptr && exif->data_sz >= 8 &&
      exif->data_sz <= (1U << 20U)) {
    const auto read = read_exif(static_cast<const std::uint8_t*>(exif->data),
                                exif->data_sz);
    codec::apply_exif(result, read);
    // Unlike HEIF, a JPEG carries its rotation only in Exif and libultrahdr
    // does not apply it, so this path normalises it into the pixels exactly as
    // the plain-JPEG decoder does.
    if (read.orientation) codec::normalize_orientation(result, *read.orientation);
  }
  if (authored_sdr.linear_p3.width != result.linear_p3.width ||
      authored_sdr.linear_p3.height != result.linear_p3.height)
    throw std::runtime_error("Ultra HDR primary and alternate dimensions disagree");
  result.authored_sdr = std::move(authored_sdr.linear_p3);
  return result;
}

}  // namespace codec

}  // namespace hyperdr
