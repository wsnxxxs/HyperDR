// BT.2100 AVIF input.
//
// AVIF was the one encoding this project could write but not read, which made
// `--encoding avif-pq` a one-way door: the file it produced was not something
// it would accept back. Reading it closes that, and it is the same job the HEIF
// decoder does -- CICP in, linear Display P3 out -- so the transfer functions,
// the primaries matrices and the ICC path all come from internal/cicp.hpp
// rather than being written a second time against libavif's spelling of the
// same code points.
//
// The bundled libavif exposes the ISO gain-map API. Preserve both its primary
// and reconstructed alternate; a failed map application is reported as a
// degraded primary-only decode.

#include "hyperdr/codec/image_source.hpp"
#include "internal/decode_bytes.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/budget.hpp"
#include "internal/cicp.hpp"
#include "internal/metadata.hpp"

#include <avif/avif.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

using codec::apply_exif;
using codec::interleaved_rgb_to_linear_p3;
using codec::normalize_orientation;
using codec::transfer_headroom;
using codec::SourceColor;

struct DecoderDeleter {
  void operator()(avifDecoder* decoder) const { avifDecoderDestroy(decoder); }
};

void check_avif(avifResult result, const char* operation) {
  if (result == AVIF_RESULT_OK) return;
  throw std::runtime_error(std::string(operation) + ": " + avifResultToString(result));
}

// The Exif orientation that `irot` and `imir` together describe.
//
// libavif reports the two boxes but never applies them, unlike libheif, so an
// AVIF whose camera shot it in portrait arrives here as a landscape raster plus
// a pair of flags. Both are mapped onto this project's single orientation
// vocabulary so the rotation is normalised into the pixels exactly once, by the
// same code every other format uses.
//
// The table is a composition, not a guess: HEIF applies `irot` before `imir`,
// `irot.angle` is anti-clockwise in units of 90 degrees, and `imir.axis` is 0
// for exchanging top with bottom and 1 for left with right. Composing those on
// a pixel (x, y) and reading the result against the Exif table gives the eight
// values below -- for instance a 90-degree anti-clockwise rotation displays the
// same picture as Exif 8, which is a 270-degree clockwise one.
std::uint16_t orientation_from_transforms(const avifImage& image) {
  const bool has_rotation = (image.transformFlags & AVIF_TRANSFORM_IROT) != 0;
  const bool has_mirror = (image.transformFlags & AVIF_TRANSFORM_IMIR) != 0;
  const unsigned angle = has_rotation ? (image.irot.angle & 3U) : 0U;
  if (!has_mirror) {
    constexpr std::uint16_t kRotationOnly[4]{1, 8, 3, 6};
    return kRotationOnly[angle];
  }
  if (image.imir.axis == 0) {  // top and bottom exchanged
    constexpr std::uint16_t kVerticalMirror[4]{4, 5, 2, 7};
    return kVerticalMirror[angle];
  }
  constexpr std::uint16_t kHorizontalMirror[4]{2, 7, 4, 5};
  return kHorizontalMirror[angle];
}

SourceColor source_color_for(const avifImage& image, ColorGamut default_gamut) {
  SourceColor color(default_gamut);
  const int transfer = static_cast<int>(image.transferCharacteristics);
  const bool hdr_transfer = transfer == codec::kCicpTransferPq ||
                            transfer == codec::kCicpTransferHlg;
  if (image.icc.data != nullptr && image.icc.size != 0 &&
      image.icc.size <= (4U << 20U) && !hdr_transfer) {
    color.icc.assign(image.icc.data, image.icc.data + image.icc.size);
    color.source = "icc";
    return color;
  }
  color.primaries = static_cast<int>(image.colorPrimaries);
  color.transfer = transfer;
  if (!codec::cicp_primaries_unspecified(color.primaries) ||
      (transfer != codec::kCicpTransferReserved &&
       transfer != codec::kCicpTransferUnspecified)) color.source = "cicp";
  if (codec::cicp_primaries_unspecified(color.primaries)) {
    color.primaries = codec::cicp_primaries_for_gamut(default_gamut);
  }
  return color;
}

}  // namespace

namespace codec {

bool is_avif_bytes(const std::vector<std::uint8_t>& bytes) {
  // The `ftyp` box that decides this sits at the very start of the file, so
  // only the head is inspected: the HEIF branch of decode_image asks this
  // question about every HEIC it opens.
  if (bytes.size() < 16) return false;
  const avifROData data{bytes.data(), std::min<std::size_t>(bytes.size(), 512)};
  return avifPeekCompatibleFileType(&data) != AVIF_FALSE;
}

}  // namespace codec

// Kept for the CLI and the codec tests. `decode_image` holds the whole file by
// the time it needs this answer and asks `codec::is_avif_bytes` instead, so
// reading a prefix here is only for callers that start from a path.
bool is_avif_file(const std::filesystem::path& path) {
  return codec::is_avif_bytes(read_binary_prefix(path, 512));
}

DecodedImage decode_avif(const std::filesystem::path& path) {
  return codec::decode_avif_bytes(read_binary_file(path), 0,
                                  ColorGamut::kSrgb);
}

namespace codec {

DecodedImage decode_avif_bytes(const std::vector<std::uint8_t>& bytes,
                              std::uint32_t preview_max_edge,
                              ColorGamut default_gamut) {
  if (bytes.empty()) throw std::runtime_error("AVIF input is empty");

  std::unique_ptr<avifDecoder, DecoderDeleter> decoder(avifDecoderCreate());
  if (!decoder) throw std::runtime_error("cannot allocate the AVIF decoder");
  // The row-parallel pool does the work after this point; one decoder thread
  // keeps the two from oversubscribing, matching the encoder's choice.
  decoder->maxThreads = 1;
#if AVIF_VERSION >= 1020000
  decoder->imageContentToDecode = AVIF_IMAGE_CONTENT_ALL;
#endif
  check_avif(avifDecoderSetIOMemory(decoder.get(), bytes.data(), bytes.size()),
             "open the AVIF");
  check_avif(avifDecoderParse(decoder.get()), "parse the AVIF");
  check_avif(avifDecoderNextImage(decoder.get()), "decode the AVIF");

  avifImage* image = decoder->image;
  if (image == nullptr || image->width == 0 || image->height == 0) {
    throw std::runtime_error("the AVIF decoded to an empty image");
  }
  if (image->depth < 8 || image->depth > 16) {
    throw std::runtime_error("unsupported AVIF bit depth " +
                             std::to_string(image->depth));
  }
  const auto source_width = image->width;
  const auto source_height = image->height;
  const auto plan = codec::raster_decode_plan(source_width, source_height, preview_max_edge);

  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, image);
  const bool has_alpha = image->alphaPlane != nullptr;
  rgb.format = has_alpha ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
  // Retain source association; the shared float converter undoes it before
  // transfer decoding and composites in linear light, avoiding integer undo.
  rgb.alphaPremultiplied = image->alphaPremultiplied;
  rgb.ignoreAlpha = AVIF_FALSE;
  rgb.depth = image->depth;
  check_avif(avifRGBImageAllocatePixels(&rgb), "allocate AVIF RGB pixels");
  struct RgbGuard {
    avifRGBImage* rgb;
    ~RgbGuard() { avifRGBImageFreePixels(rgb); }
  } guard{&rgb};
  check_avif(avifImageYUVToRGB(image, &rgb), "convert AVIF YUV to RGB");

  const SourceColor color = source_color_for(*image, default_gamut);
  DecodedImage result;
  result.source_color = describe_source_color(color);
  result.linear_p3 = interleaved_rgb_to_linear_p3(
      rgb.pixels, rgb.width, rgb.height, rgb.rowBytes, static_cast<int>(rgb.depth),
      color, plan.width, plan.height, !has_alpha ? RgbAlpha::None
          : image->alphaPremultiplied ? RgbAlpha::Premultiplied : RgbAlpha::Straight);
  result.decode.sensor_width = result.decode.target_width = source_width;
  result.decode.sensor_height = result.decode.target_height = source_height;
  result.decode.decoded_width = plan.width;
  result.decode.decoded_height = plan.height;
  result.decode.resolution_reduced = plan.budget_limited;
  result.metadata.orientation = 1;
  // PQ/HLG CICP determines transfer and range even beside an ICC profile.
  result.hdr_headroom = transfer_headroom(color.transfer);
  if (result.hdr_headroom > 1.0F && image->clli.maxCLL != 0)
    result.content_peak_nits = static_cast<float>(image->clli.maxCLL);
  result.domain = display_referred_domain(result.hdr_headroom);

#if AVIF_VERSION >= 1020000
  if (image->gainMap != nullptr) {
    const auto* map = image->gainMap;
    const bool primary_is_hdr =
        static_cast<double>(map->baseHdrHeadroom.n) / map->baseHdrHeadroom.d >
        static_cast<double>(map->alternateHdrHeadroom.n) / map->alternateHdrHeadroom.d;
    if (map->image == nullptr || map->image->yuvPlanes[AVIF_CHAN_Y] == nullptr) {
      result.decode.degraded = true;
      result.decode.degradation_reasons.push_back("avif_gain_map_pixels_unavailable_sdr_fallback");
    } else {
      avifRGBImage alternate{};
      avifRGBImageSetDefaults(&alternate, image);
      alternate.format = has_alpha ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
      alternate.depth = 16;
      alternate.isFloat = AVIF_FALSE;
      const auto status = avifRGBImageApplyGainMap(
          &rgb, image->colorPrimaries, image->transferCharacteristics, map,
          static_cast<float>(map->alternateHdrHeadroom.n) /
              static_cast<float>(map->alternateHdrHeadroom.d),
          AVIF_COLOR_PRIMARIES_SMPTE432,
          AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084,
          &alternate, nullptr, &decoder->diag);
      if (status != AVIF_RESULT_OK) {
        avifRGBImageFreePixels(&alternate);
        result.decode.degraded = true;
        result.decode.degradation_reasons.push_back(
            std::string("avif_gain_map_apply_failed_sdr_fallback:") +
            avifResultToString(status) + ":" + decoder->diag.error);
      } else {
        struct AlternateGuard {
          avifRGBImage* rgb;
          ~AlternateGuard() { avifRGBImageFreePixels(rgb); }
        } alternate_guard{&alternate};
        SourceColor alternate_color(ColorGamut::kDisplayP3);
        alternate_color.transfer = kCicpTransferPq;
        FloatImage secondary = interleaved_rgb_to_linear_p3(
            alternate.pixels, alternate.width, alternate.height,
            alternate.rowBytes, static_cast<int>(alternate.depth),
            alternate_color, plan.width, plan.height,
            !has_alpha ? RgbAlpha::None : RgbAlpha::Straight);
        if (primary_is_hdr) {
          result.authored_sdr = std::move(secondary);
        } else {
          result.authored_sdr = std::move(result.linear_p3);
          result.linear_p3 = std::move(secondary);
        }
        result.gain_map.channels = map->image->yuvFormat == AVIF_PIXEL_FORMAT_YUV400 ? 1U : 3U;
        const float primary_headroom = std::exp2(
            static_cast<float>(map->baseHdrHeadroom.n) / map->baseHdrHeadroom.d);
        const float secondary_headroom = std::exp2(
            static_cast<float>(map->alternateHdrHeadroom.n) / map->alternateHdrHeadroom.d);
        result.gain_map.base_headroom = primary_is_hdr ? secondary_headroom : primary_headroom;
        result.gain_map.alternate_headroom = primary_is_hdr ? primary_headroom : secondary_headroom;
        for (unsigned c = 0; c < 3; ++c) {
          const float primary_offset =
              static_cast<float>(map->baseOffset[c].n) / map->baseOffset[c].d;
          const float secondary_offset =
              static_cast<float>(map->alternateOffset[c].n) / map->alternateOffset[c].d;
          result.gain_map.base_offset[c] = primary_is_hdr ? secondary_offset : primary_offset;
          result.gain_map.alternate_offset[c] = primary_is_hdr ? primary_offset : secondary_offset;
        }
        result.hdr_headroom = measured_alternate_headroom(result.linear_p3);
        result.content_peak_nits.reset();
        result.domain = InputDomain::kDualRendition;
      }
    }
  }
#endif

  // The container's own transforms are authoritative when present, which is
  // what the HEIF family says and what libavif's encoder assumes when it folds
  // an Exif Orientation into irot/imir on the way in. Exif is only consulted
  // for rotation when neither box is there, so a file that states it twice
  // cannot be rotated twice.
  ExifRead exif;
  if (image->exif.data != nullptr && image->exif.size >= 8 &&
      image->exif.size <= (1U << 20U)) {
    exif = read_exif(image->exif.data, image->exif.size);
  }
  apply_exif(result, exif);
  const bool container_states_orientation =
      (image->transformFlags & (AVIF_TRANSFORM_IROT | AVIF_TRANSFORM_IMIR)) != 0;
  const std::uint16_t orientation =
      container_states_orientation ? orientation_from_transforms(*image)
                                   : exif.orientation.value_or(1);
  normalize_orientation(result, orientation);
  return result;
}

}  // namespace codec

}  // namespace hyperdr
