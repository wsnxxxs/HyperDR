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
#include "hyperdr/codec/avif_grid.hpp"
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
#include <thread>
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

std::vector<std::uint8_t> encode_avif(const PhotoRenditions& images,
                                      const PhotoMetadata& metadata, int quality,
                                      HdrEncoding encoding, const AvifGridLayout* requested) {
  if (encoding != HdrEncoding::AvifPq && encoding != HdrEncoding::AvifHlg) {
    throw std::invalid_argument("encode_avif requires an AVIF encoding");
  }
  const auto& hdr = images.hdr;
  const auto layout = requested ? *requested : avif_grid_layout(hdr.width, hdr.height);
  const bool grid = layout.is_grid();
  if (grid) {
    // libavif: at most 256 per axis, identical cells but the last column and
    // row, which may be smaller and never larger.
    const auto last_width = hdr.width - (layout.columns - 1) * layout.cell_width;
    const auto last_height = hdr.height - (layout.rows - 1) * layout.cell_height;
    if (layout.columns > 256 || layout.rows > 256 || layout.cell_width == 0 || layout.cell_height == 0 ||
        (layout.columns - 1) * std::uint64_t(layout.cell_width) >= hdr.width ||
        (layout.rows - 1) * std::uint64_t(layout.cell_height) >= hdr.height ||
        last_width > layout.cell_width || last_height > layout.cell_height) {
      throw std::invalid_argument("invalid AVIF grid layout");
    }
  }

  const auto make_image = [&](std::uint32_t width, std::uint32_t height) {
    std::unique_ptr<avifImage, ImageDeleter> image(
        avifImageCreate(width, height, kDepth, AVIF_PIXEL_FORMAT_YUV444));
    if (!image) throw std::runtime_error("cannot allocate the AVIF image");
    image->yuvRange = AVIF_RANGE_FULL;
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT2020;
    image->transferCharacteristics = static_cast<avifTransferCharacteristics>(
        encoding == HdrEncoding::AvifPq ? AVIF_TRANSFER_CHARACTERISTICS_SMPTE2084
                                        : AVIF_TRANSFER_CHARACTERISTICS_HLG);
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT2020_NCL;
    return image;
  };

  // Quantizes the region [x0, x0+width) x [y0, y0+height) of the HDR canvas
  // into `image` (one whole image, or one grid cell). The dither depends on
  // canvas coordinates only, so a cell holds exactly the codes the single item
  // would hold there. Peak and light level fold into the canvas-wide totals.
  constexpr unsigned max_code = (1U << kDepth) - 1U;
  std::vector<float> row_peak(hdr.height, 0.0F);
  std::vector<double> row_light_level(hdr.height, 0.0);
  const auto convert_region = [&](avifImage* image, std::uint32_t x0, std::uint32_t y0) {
    avifRGBImage rgb{};
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = AVIF_RGB_FORMAT_RGB;
    rgb.depth = kDepth;
    check_avif(avifRGBImageAllocatePixels(&rgb), "allocate AVIF RGB pixels");
    struct RgbGuard {
      avifRGBImage* rgb;
      ~RgbGuard() { avifRGBImageFreePixels(rgb); }
    } guard{&rgb};
    parallel_for_rows(image->height, [&](const std::uint32_t row_in_region) {
      const auto y = y0 + row_in_region;
      auto* row = reinterpret_cast<std::uint16_t*>(
          rgb.pixels + static_cast<std::size_t>(row_in_region) * rgb.rowBytes);
      float peak = 0.0F;
      double light_level_sum = 0.0;
      for (std::uint32_t column = 0; column < image->width; ++column) {
        const auto x = x0 + column;
        const auto wide = p3_to_rec2020(hdr.at(x, y, 0), hdr.at(x, y, 1), hdr.at(x, y, 2));
        const std::array<float, 3> linear{std::max(0.0F, wide[0]), std::max(0.0F, wide[1]),
                                          std::max(0.0F, wide[2])};
        const float light_level = std::max({linear[0], linear[1], linear[2]});
        peak = std::max(peak, light_level);
        light_level_sum += light_level;
        const auto encoded = encoding == HdrEncoding::AvifPq
                                 ? std::array<float, 3>{pq_oetf(linear[0]), pq_oetf(linear[1]),
                                                        pq_oetf(linear[2])}
                                 : hlg_encode(linear);
        for (unsigned channel = 0; channel < 3; ++channel) {
          // Same dithered quantization as the HEIC path: the gain map multiplies
          // quantization error, so undithered 10-bit skies band visibly.
          row[column * 3U + channel] = static_cast<std::uint16_t>(
              quantize_dithered(encoded[channel], max_code, x, y, channel));
        }
      }
      // A grid row is visited once per cell column: fold into the canvas row.
      row_peak[y] = std::max(row_peak[y], peak);
      row_light_level[y] += light_level_sum;
    });
    check_avif(avifImageRGBToYUV(image, &rgb), "convert AVIF RGB to YUV");
  };

  std::unique_ptr<avifImage, ImageDeleter> image;
  std::vector<std::unique_ptr<avifImage, ImageDeleter>> cells;
  if (!grid) {
    image = make_image(hdr.width, hdr.height);
    convert_region(image.get(), 0, 0);
  } else {
    // Each cell is converted on its own, so the canvas-sized RGB buffer never
    // exists next to the YUV cells.
    for (std::uint32_t row = 0; row < layout.rows; ++row) {
      for (std::uint32_t column = 0; column < layout.columns; ++column) {
        const auto x0 = column * layout.cell_width, y0 = row * layout.cell_height;
        auto cell = make_image(std::min(layout.cell_width, hdr.width - x0),
                               std::min(layout.cell_height, hdr.height - y0));
        convert_region(cell.get(), x0, y0);
        cells.push_back(std::move(cell));
      }
    }
  }
  avifImage* const first = grid ? cells.front().get() : image.get();

  const float peak = *std::max_element(row_peak.begin(), row_peak.end());
  const double light_level_sum =
      std::accumulate(row_light_level.begin(), row_light_level.end(), 0.0);
  const double pixel_count = static_cast<double>(hdr.width) * hdr.height;
  const auto clamp_light = [](double nits) {
    return static_cast<std::uint16_t>(std::clamp(std::ceil(nits), 0.0, 10000.0));
  };
  // A grid takes its properties from the first cell.
  first->clli.maxCLL = clamp_light(peak * kReferenceWhiteNits);
  first->clli.maxPALL =
      clamp_light(pixel_count > 0.0
                      ? light_level_sum * kReferenceWhiteNits / pixel_count
                      : 0.0);

  const auto exif = make_minimal_exif(metadata);
  check_avif(avifImageSetMetadataExif(first, exif.data(), exif.size()), "attach AVIF Exif");
  const auto xmp = make_xmp(metadata, images.stats.headroom_stops,
                            /*has_gain_map=*/false);
  check_avif(avifImageSetMetadataXMP(first,
                                     reinterpret_cast<const std::uint8_t*>(xmp.data()),
                                     xmp.size()),
             "attach AVIF XMP");

  std::unique_ptr<avifEncoder, EncoderDeleter> encoder(avifEncoderCreate());
  if (!encoder) throw std::runtime_error("cannot allocate the AVIF encoder");
  encoder->quality = std::clamp(quality, 0, 100);
  encoder->qualityAlpha = AVIF_QUALITY_LOSSLESS;
  encoder->speed = 6;
  // Batch exports run one file at a time, and row conversion is complete here.
  // Give the AV1 codec several cores without creating an unbounded worker pool.
  encoder->maxThreads = static_cast<int>(
      std::min(8U, std::max(1U, std::thread::hardware_concurrency())));

  avifRWData output = AVIF_DATA_EMPTY;
  struct DataGuard {
    avifRWData* data;
    ~DataGuard() { avifRWDataFree(data); }
  } output_guard{&output};
  if (!grid) {
    check_avif(avifEncoderWrite(encoder.get(), first, &output), "write AVIF");
  } else {
    std::vector<const avifImage*> pointers;
    for (const auto& cell : cells) pointers.push_back(cell.get());
    check_avif(avifEncoderAddImageGrid(encoder.get(), layout.columns, layout.rows, pointers.data(),
                                       AVIF_ADD_IMAGE_FLAG_SINGLE),
               "add AVIF grid");
    check_avif(avifEncoderFinish(encoder.get(), &output), "write AVIF grid");
  }
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
  if (image->matrixCoefficients != AVIF_MATRIX_COEFFICIENTS_BT2020_NCL) {
    throw std::runtime_error("the encoded AVIF does not carry a BT.2020 YCbCr matrix");
  }
}

}  // namespace hyperdr
