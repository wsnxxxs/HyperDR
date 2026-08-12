// BT.2100 AVIF output.
//
// AVIF was previously out of scope, which left the project unable to target
// the one HDR still format Chrome and Android treat as first class. This uses
// only libavif's stable encoder API and the same reconstructed linear HDR
// image, the same P3 -> Rec.2020 matrix, and the same PQ/HLG transfer
// functions as the HEIC path, so `--encoding pq` and `--encoding avif-pq`
// differ in container and codec alone, never in rendition.
//
// Gain-map AVIF is deliberately not attempted here: libavif's gain-map support
// is behind an experimental build flag whose API is still moving, and shipping
// a format whose metadata could change under a dependency bump is worse than
// not shipping it. Adaptive HEIC and Ultra HDR JPEG remain the gain-map paths.

#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/transfer.hpp"

#include <avif/avif.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

constexpr int kDepth = 10;

struct ImageDeleter {
  void operator()(avifImage* image) const { avifImageDestroy(image); }
};
struct EncoderDeleter {
  void operator()(avifEncoder* encoder) const { avifEncoderDestroy(encoder); }
};
struct DecoderDeleter {
  void operator()(avifDecoder* decoder) const { avifDecoderDestroy(decoder); }
};

void check_avif(avifResult result, const char* operation) {
  if (result == AVIF_RESULT_OK) return;
  throw std::runtime_error(std::string(operation) + ": " + avifResultToString(result));
}

}  // namespace

std::vector<std::uint8_t> encode_avif(const GainMapResult& images,
                                      const PhotoMetadata& metadata, int quality,
                                      HdrEncoding encoding) {
  if (encoding != HdrEncoding::AvifPq && encoding != HdrEncoding::AvifHlg) {
    throw std::invalid_argument("encode_avif requires an AVIF encoding");
  }
  auto hdr = reconstruct_gain_map(images.base_linear, images.gain_map, images.metadata,
                                  images.headroom_stops);

  std::unique_ptr<avifImage, ImageDeleter> image(
      avifImageCreate(static_cast<uint32_t>(hdr.width), static_cast<uint32_t>(hdr.height),
                      kDepth, AVIF_PIXEL_FORMAT_YUV444));
  if (!image) throw std::runtime_error("cannot allocate the AVIF image");
  image->yuvRange = AVIF_RANGE_FULL;
  image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
  image->transferCharacteristics = static_cast<avifTransferCharacteristics>(
      encoding == HdrEncoding::AvifPq ? AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084
                                      : AVIF_TRANSFER_CHARACTERISTICS_HLG);
  image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;

  avifRGBImage rgb{};
  avifRGBImageSetDefaults(&rgb, image.get());
  rgb.format = AVIF_RGB_FORMAT_RGB;
  rgb.depth = kDepth;
  check_avif(avifRGBImageAllocatePixels(&rgb), "allocate AVIF RGB pixels");
  struct RgbGuard {
    avifRGBImage* rgb;
    ~RgbGuard() { avifRGBImageFreePixels(rgb); }
  } guard{&rgb};

  constexpr unsigned max_code = (1U << kDepth) - 1U;
  std::vector<float> row_peak(hdr.height, 0.0F);
  std::vector<double> row_luminance(hdr.height, 0.0);
  parallel_for_rows(hdr.height, [&](const std::uint32_t y) {
    auto* row = reinterpret_cast<std::uint16_t*>(rgb.pixels +
                                                 static_cast<std::size_t>(y) * rgb.rowBytes);
    float peak = 0.0F;
    double luminance_sum = 0.0;
    for (std::uint32_t x = 0; x < hdr.width; ++x) {
      const auto wide = p3_to_rec2020(hdr.at(x, y, 0), hdr.at(x, y, 1), hdr.at(x, y, 2));
      const std::array<float, 3> linear{std::max(0.0F, wide[0]), std::max(0.0F, wide[1]),
                                        std::max(0.0F, wide[2])};
      peak = std::max(peak, std::max({linear[0], linear[1], linear[2]}));
      luminance_sum += 0.2627 * linear[0] + 0.6780 * linear[1] + 0.0593 * linear[2];
      for (unsigned channel = 0; channel < 3; ++channel) {
        const float encoded = encoding == HdrEncoding::AvifPq ? pq_oetf(linear[channel])
                                                              : hlg_oetf(linear[channel]);
        // Same dithered quantization as the HEIC path: the gain map multiplies
        // quantization error, so undithered 10-bit skies band visibly.
        row[x * 3U + channel] =
            static_cast<std::uint16_t>(quantize_dithered(encoded, max_code, x, y, channel));
      }
    }
    row_peak[y] = peak;
    row_luminance[y] = luminance_sum;
  });
  check_avif(avifImageRGBToYUV(image.get(), &rgb), "convert AVIF RGB to YUV");

  const float peak = *std::max_element(row_peak.begin(), row_peak.end());
  const double luminance_sum =
      std::accumulate(row_luminance.begin(), row_luminance.end(), 0.0);
  const double pixel_count = static_cast<double>(hdr.width) * hdr.height;
  const auto clamp_light = [](double nits) {
    return static_cast<std::uint16_t>(std::clamp(std::ceil(nits), 0.0, 65535.0));
  };
  image->clli.maxCLL = clamp_light(peak * kReferenceWhiteNits);
  image->clli.maxPALL =
      clamp_light(pixel_count > 0.0 ? luminance_sum * kReferenceWhiteNits / pixel_count : 0.0);

  const auto exif = make_minimal_exif(metadata);
  check_avif(avifImageSetMetadataExif(image.get(), exif.data(), exif.size()),
             "attach AVIF Exif");
  const auto xmp = make_xmp(metadata, images.headroom_stops,
                            /*has_gain_map=*/false);
  check_avif(avifImageSetMetadataXMP(image.get(),
                                     reinterpret_cast<const std::uint8_t*>(xmp.data()),
                                     xmp.size()),
             "attach AVIF XMP");

  std::unique_ptr<avifEncoder, EncoderDeleter> encoder(avifEncoderCreate());
  if (!encoder) throw std::runtime_error("cannot allocate the AVIF encoder");
  encoder->quality = std::clamp(quality, 0, 100);
  encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
  encoder->speed = 6;
  // libavif's own thread pool; the row-parallel pool above has already finished
  // by this point, so this does not oversubscribe.
  encoder->maxThreads = 1;

  avifRWData output = AVIF_DATA_EMPTY;
  struct DataGuard {
    avifRWData* data;
    ~DataGuard() { avifRWDataFree(data); }
  } output_guard{&output};
  check_avif(avifEncoderWrite(encoder.get(), image.get(), &output), "write AVIF");
  if (output.data == nullptr || output.size == 0) {
    throw std::runtime_error("AVIF encoder produced no output");
  }
  return {output.data, output.data + output.size};
}

void verify_avif_decodable(const std::vector<std::uint8_t>& bytes) {
  std::unique_ptr<avifDecoder, DecoderDeleter> decoder(avifDecoderCreate());
  if (!decoder) throw std::runtime_error("cannot allocate the AVIF decoder");
  decoder->maxThreads = 1;
  check_avif(avifDecoderSetIOMemory(decoder.get(), bytes.data(), bytes.size()),
             "open the encoded AVIF");
  check_avif(avifDecoderParse(decoder.get()), "parse the encoded AVIF");
  check_avif(avifDecoderNextImage(decoder.get()), "decode the encoded AVIF");
  const auto* image = decoder->image;
  if (image == nullptr || image->width == 0 || image->height == 0) {
    throw std::runtime_error("the encoded AVIF decoded to an empty image");
  }
  if (image->depth != kDepth) {
    throw std::runtime_error("the encoded AVIF is not 10-bit");
  }
  if (image->colorPrimaries != AVIF_COLOR_PRIMARIES_BT2020) {
    throw std::runtime_error("the encoded AVIF does not carry Rec.2020 primaries");
  }
  if (image->transferCharacteristics != AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084 &&
      image->transferCharacteristics != AVIF_TRANSFER_CHARACTERISTICS_HLG) {
    throw std::runtime_error("the encoded AVIF does not carry a BT.2100 transfer function");
  }
}

}  // namespace hyperdr
