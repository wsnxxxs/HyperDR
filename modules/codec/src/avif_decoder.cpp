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
// Gain-map AVIF is read as its base image, deliberately and symmetrically with
// the encoder: libavif's gain-map support is behind an experimental build flag
// whose API is still moving (see the note at the top of avif_encoder.cpp), so
// neither half of this project depends on it. An Ultra HDR AVIF therefore
// arrives as its SDR base rather than failing, which is the same fallback the
// JPEG/R path takes when its gain map will not parse.

#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/budget.hpp"
#include "internal/cicp.hpp"
#include "internal/metadata.hpp"

#include <avif/avif.h>

#include <algorithm>
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
using codec::raster_budget_ok;
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

SourceColor source_color_for(const avifImage& image) {
  SourceColor color;
  if (image.icc.data != nullptr && image.icc.size != 0 &&
      image.icc.size <= (4U << 20U)) {
    color.icc.assign(image.icc.data, image.icc.data + image.icc.size);
    return color;
  }
  color.primaries = static_cast<int>(image.colorPrimaries);
  color.transfer = static_cast<int>(image.transferCharacteristics);
  return color;
}

// libavif has no scaled-decode entry point, so the full raster is resident by
// the time the budget can be checked -- the same position the HEIC path is in.
// Shrinking before the float working buffer is allocated is what the budget is
// protecting, because that buffer is the larger of the two.
bool fit_to_budget(avifImage* image) {
  if (raster_budget_ok(image->width, image->height)) return false;
  std::uint32_t factor = 2;
  while (factor <= 64 &&
         !raster_budget_ok((static_cast<std::uint64_t>(image->width) + factor - 1) / factor,
                           (static_cast<std::uint64_t>(image->height) + factor - 1) / factor)) {
    ++factor;
  }
  if (factor > 64) {
    throw std::runtime_error("AVIF image exceeds the pixel or memory budget");
  }
  check_avif(avifImageScale(image, std::max(1U, image->width / factor),
                            std::max(1U, image->height / factor), nullptr),
             "AVIF downscale");
  return true;
}

}  // namespace

bool is_avif_file(const std::filesystem::path& path) {
  // The `ftyp` box that decides this sits at the very start of the file, so
  // only the head is read: the HEIF branch of decode_image asks this question
  // about every HEIC it opens, and answering it by reading a 50 MB image would
  // double the cost of decoding one.
  const auto head = read_binary_prefix(path, 512);
  if (head.size() < 16) return false;
  const avifROData data{head.data(), head.size()};
  return avifPeekCompatibleFileType(&data) != AVIF_FALSE;
}

DecodedImage decode_avif(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  if (bytes.empty()) throw std::runtime_error("AVIF input is empty");

  std::unique_ptr<avifDecoder, DecoderDeleter> decoder(avifDecoderCreate());
  if (!decoder) throw std::runtime_error("cannot allocate the AVIF decoder");
  // The row-parallel pool does the work after this point; one decoder thread
  // keeps the two from oversubscribing, matching the encoder's choice.
  decoder->maxThreads = 1;
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
  const bool resolution_reduced = fit_to_budget(image);

  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, image);
  rgb.format = AVIF_RGB_FORMAT_RGB;
  rgb.depth = image->depth;
  check_avif(avifRGBImageAllocatePixels(&rgb), "allocate AVIF RGB pixels");
  struct RgbGuard {
    avifRGBImage* rgb;
    ~RgbGuard() { avifRGBImageFreePixels(rgb); }
  } guard{&rgb};
  check_avif(avifImageYUVToRGB(image, &rgb), "convert AVIF YUV to RGB");

  const SourceColor color = source_color_for(*image);
  DecodedImage result;
  result.linear_p3 = interleaved_rgb_to_linear_p3(
      rgb.pixels, rgb.width, rgb.height, rgb.rowBytes, static_cast<int>(rgb.depth),
      color);
  result.decode.sensor_width = rgb.width;
  result.decode.sensor_height = rgb.height;
  result.decode.target_width = rgb.width;
  result.decode.target_height = rgb.height;
  result.decode.decoded_width = rgb.width;
  result.decode.decoded_height = rgb.height;
  result.decode.resolution_reduced = resolution_reduced;
  result.metadata.orientation = 1;
  // As in the HEIF path: an ICC profile carries no headroom, so an ICC-tagged
  // AVIF is read as SDR and rendered faithfully rather than speculatively.
  result.hdr_headroom = color.icc.empty() ? transfer_headroom(color.transfer) : 1.0F;
  result.domain = display_referred_domain(result.hdr_headroom);

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

}  // namespace hyperdr
