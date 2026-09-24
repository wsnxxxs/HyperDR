#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/image/transfer.hpp"
#include "internal/budget.hpp"
#include "internal/cicp.hpp"
#include "internal/icc_profiles.hpp"
#include "internal/metadata.hpp"

#include <tiffio.h>

#include <algorithm>
#include <array>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace codec {
namespace {

struct MemoryFile {
  std::vector<std::uint8_t> bytes;
  const std::vector<std::uint8_t>* input{};
  std::uint64_t position{};
  bool writable{};
  const std::vector<std::uint8_t>& contents() const { return input ? *input : bytes; }
};

tmsize_t read_memory(thandle_t handle, void* destination, tmsize_t count) {
  auto& file = *static_cast<MemoryFile*>(handle);
  const auto& contents = file.contents();
  if (count <= 0 || file.position >= contents.size()) return 0;
  const auto available = contents.size() - static_cast<std::size_t>(file.position);
  const auto size = std::min<std::size_t>(available, static_cast<std::size_t>(count));
  std::memcpy(destination, contents.data() + file.position, size);
  file.position += size;
  return static_cast<tmsize_t>(size);
}

tmsize_t write_memory(thandle_t handle, void* source, tmsize_t count) {
  auto& file = *static_cast<MemoryFile*>(handle);
  if (!file.writable || count < 0) return 0;
  const auto size = static_cast<std::uint64_t>(count);
  if (file.position > std::numeric_limits<std::size_t>::max() - size) return 0;
  const auto end = static_cast<std::size_t>(file.position + size);
  if (end > file.bytes.size()) file.bytes.resize(end);
  std::memcpy(file.bytes.data() + file.position, source, static_cast<std::size_t>(size));
  file.position += size;
  return count;
}

toff_t seek_memory(thandle_t handle, toff_t offset, int origin) {
  auto& file = *static_cast<MemoryFile*>(handle);
  const auto base = origin == SEEK_SET ? 0 : origin == SEEK_CUR
      ? static_cast<std::int64_t>(file.position)
      : origin == SEEK_END ? static_cast<std::int64_t>(file.contents().size()) : -1;
  if (base < 0) return static_cast<toff_t>(-1);
  const auto displacement = static_cast<std::int64_t>(offset);
  if ((displacement < 0 && -displacement > base) ||
      (displacement > 0 && base > std::numeric_limits<std::int64_t>::max() - displacement))
    return static_cast<toff_t>(-1);
  const auto target = base + displacement;
  file.position = static_cast<std::uint64_t>(target);
  return static_cast<toff_t>(file.position);
}

int close_memory(thandle_t) { return 0; }
toff_t size_memory(thandle_t handle) {
  return static_cast<toff_t>(static_cast<MemoryFile*>(handle)->contents().size());
}
int map_memory(thandle_t, void**, toff_t*) { return 0; }
void unmap_memory(thandle_t, void*, toff_t) {}

struct TiffCloser {
  void operator()(TIFF* tiff) const { if (tiff) TIFFClose(tiff); }
};
using TiffHandle = std::unique_ptr<TIFF, TiffCloser>;

TiffHandle open_tiff(MemoryFile& file, const char* mode) {
  TiffHandle tiff(TIFFClientOpen("HyperDR TIFF", mode, &file, read_memory, write_memory,
                                 seek_memory, close_memory, size_memory, map_memory,
                                 unmap_memory));
  if (!tiff) throw std::runtime_error("cannot open TIFF");
  return tiff;
}

void put_u16(std::uint8_t* target, std::uint16_t value) {
  target[0] = static_cast<std::uint8_t>(value);
  target[1] = static_cast<std::uint8_t>(value >> 8);
}

}  // namespace

DecodedImage decode_tiff_bytes(const std::vector<std::uint8_t>& bytes,
                               std::uint32_t preview_max_edge,
                               ColorGamut default_gamut) {
  MemoryFile file;
  file.input = &bytes;
  auto tiff = open_tiff(file, "rm");
  if (TIFFIsTiled(tiff.get())) throw std::runtime_error("tiled TIFF is not supported");
  std::uint32_t width = 0, height = 0;
  std::uint16_t bits = 0, samples = 0, photometric = 0, planar = 0, sample_format = 0;
  if (!TIFFGetField(tiff.get(), TIFFTAG_IMAGEWIDTH, &width) ||
      !TIFFGetField(tiff.get(), TIFFTAG_IMAGELENGTH, &height))
    throw std::runtime_error("TIFF has no image dimensions");
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_BITSPERSAMPLE, &bits);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_SAMPLESPERPIXEL, &samples);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_PHOTOMETRIC, &photometric);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_PLANARCONFIG, &planar);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_SAMPLEFORMAT, &sample_format);
  const bool gray = photometric == PHOTOMETRIC_MINISBLACK ||
                    photometric == PHOTOMETRIC_MINISWHITE;
  const bool rgb = photometric == PHOTOMETRIC_RGB;
  if (!width || !height || (bits != 8 && bits != 16) ||
      sample_format != SAMPLEFORMAT_UINT || planar != PLANARCONFIG_CONTIG ||
      !(gray ? samples == 1 : rgb && samples == 3))
    throw std::runtime_error("TIFF requires contiguous unsigned 8/16-bit RGB or grayscale samples");
  const auto row_bytes = static_cast<std::size_t>(width) * samples * (bits / 8);
  if (TIFFScanlineSize(tiff.get()) != static_cast<tmsize_t>(row_bytes))
    throw std::runtime_error("unsupported TIFF scanline layout");

  SourceColor color(default_gamut);
  std::uint32_t icc_size = 0;
  void* icc_data = nullptr;
  if (TIFFGetField(tiff.get(), TIFFTAG_ICCPROFILE, &icc_size, &icc_data) &&
      icc_size && icc_data) {
    color.icc.assign(static_cast<std::uint8_t*>(icc_data),
                     static_cast<std::uint8_t*>(icc_data) + icc_size);
    color.source = "icc";
  }
  const RgbRowTransform transform(color, bits, false, gray);
  const auto plan = raster_decode_plan(width, height, preview_max_edge);
  FloatImage linear(plan.width, plan.height, 3);
  const bool reduce = plan.width != width || plan.height != height;
  const std::size_t source_stride = static_cast<std::size_t>(width) * 3;
  const std::size_t output_stride = static_cast<std::size_t>(plan.width) * 3;
  std::vector<std::uint8_t> scanline(row_bytes);
  std::vector<std::uint8_t> expanded(gray ? static_cast<std::size_t>(width) * 3 * (bits / 8) : 0);
  std::vector<float> source(reduce ? source_stride : 0);
  std::vector<float> horizontal(reduce ? output_stride : 0);
  std::uint32_t next_row = 0, loaded_row = height;
  const auto read_row = [&](std::uint32_t y) {
    if (TIFFReadScanline(tiff.get(), scanline.data(), y) < 0)
      throw std::runtime_error("TIFF scanline decode failed");
    const std::uint8_t* pixels = scanline.data();
    if (gray) {
      const unsigned max_code = (1U << bits) - 1U;
      for (std::uint32_t x = 0; x < width; ++x) {
        std::uint16_t wide = 0;
        if (bits == 16) std::memcpy(&wide, scanline.data() + static_cast<std::size_t>(x) * 2, 2);
        unsigned value = bits == 8 ? scanline[x] : wide;
        if (photometric == PHOTOMETRIC_MINISWHITE) value = max_code - value;
        if (bits == 8) {
          for (unsigned c = 0; c < 3; ++c) expanded[x * 3 + c] = static_cast<std::uint8_t>(value);
        } else {
          for (unsigned c = 0; c < 3; ++c) put_u16(expanded.data() + (x * 3 + c) * 2,
                                                    static_cast<std::uint16_t>(value));
        }
      }
      pixels = expanded.data();
    } else if (bits == 16 && std::endian::native == std::endian::big) {
      for (std::size_t i = 0; i < row_bytes; i += 2) std::swap(scanline[i], scanline[i + 1]);
    }
    if (!reduce) {
      transform.convert(pixels, linear.pixels.data() + static_cast<std::size_t>(y) * output_stride,
                        width);
      return;
    }
    transform.convert(pixels, source.data(), width);
    for (std::uint32_t ox = 0; ox < plan.width; ++ox) {
      const auto left = static_cast<std::uint64_t>(ox) * width;
      const auto right = static_cast<std::uint64_t>(ox + 1) * width;
      std::array<double, 3> sum{};
      for (auto sx = left / plan.width; sx <= (right - 1) / plan.width; ++sx) {
        const double weight = static_cast<double>(
            std::min(right, (sx + 1) * plan.width) - std::max(left, sx * plan.width)) / width;
        for (unsigned c = 0; c < 3; ++c) sum[c] += source[sx * 3 + c] * weight;
      }
      for (unsigned c = 0; c < 3; ++c)
        horizontal[static_cast<std::size_t>(ox) * 3 + c] = static_cast<float>(sum[c]);
    }
  };
  for (std::uint32_t oy = 0; oy < plan.height; ++oy) {
    const auto top = static_cast<std::uint64_t>(oy) * height;
    const auto bottom = static_cast<std::uint64_t>(oy + 1) * height;
    auto* target = linear.pixels.data() + static_cast<std::size_t>(oy) * output_stride;
    for (auto sy = top / plan.height; sy <= (bottom - 1) / plan.height; ++sy) {
      if (sy != loaded_row) {
        if (sy != next_row) throw std::runtime_error("TIFF rows are out of order");
        read_row(static_cast<std::uint32_t>(sy));
        loaded_row = static_cast<std::uint32_t>(sy);
        ++next_row;
      }
      if (reduce) {
        const float weight = static_cast<float>(static_cast<double>(
            std::min(bottom, (sy + 1) * plan.height) - std::max(top, sy * plan.height)) / height);
        for (std::size_t i = 0; i < output_stride; ++i) target[i] += horizontal[i] * weight;
      }
    }
  }
  DecodedImage result;
  result.source_color = describe_source_color(color);
  result.linear_p3 = std::move(linear);
  result.decode.sensor_width = result.decode.target_width = width;
  result.decode.sensor_height = result.decode.target_height = height;
  result.decode.decoded_width = plan.width;
  result.decode.decoded_height = plan.height;
  result.decode.resolution_reduced = plan.budget_limited;
  const auto exif = read_exif(bytes.data(), bytes.size());
  apply_exif(result, exif);
  normalize_orientation(result, exif.orientation.value_or(1));
  result.hdr_headroom = 1.0F;
  result.domain = InputDomain::kDisplayReferredSdr;
  return result;
}

}  // namespace codec

std::vector<std::uint8_t> encode_sdr_tiff(const FloatImage& image,
                                          const PhotoMetadata& metadata, ColorGamut gamut) {
  image.require_consistent("SDR TIFF");
  if (image.channels != 3) throw std::invalid_argument("SDR TIFF requires RGB pixels");
  if (gamut != ColorGamut::kSrgb && gamut != ColorGamut::kDisplayP3)
    throw std::invalid_argument("SDR TIFF supports sRGB or Display P3");
  codec::MemoryFile file;
  file.writable = true;
  {
    auto tiff = codec::open_tiff(file, "wm");
    if (!TIFFSetField(tiff.get(), TIFFTAG_IMAGEWIDTH, image.width) ||
        !TIFFSetField(tiff.get(), TIFFTAG_IMAGELENGTH, image.height) ||
        !TIFFSetField(tiff.get(), TIFFTAG_SAMPLESPERPIXEL, 3) ||
        !TIFFSetField(tiff.get(), TIFFTAG_BITSPERSAMPLE, 16) ||
        !TIFFSetField(tiff.get(), TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT) ||
        !TIFFSetField(tiff.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB) ||
        !TIFFSetField(tiff.get(), TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG) ||
        !TIFFSetField(tiff.get(), TIFFTAG_COMPRESSION, COMPRESSION_ADOBE_DEFLATE) ||
        !TIFFSetField(tiff.get(), TIFFTAG_PREDICTOR, PREDICTOR_HORIZONTAL) ||
        !TIFFSetField(tiff.get(), TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT) ||
        !TIFFSetField(tiff.get(), TIFFTAG_ROWSPERSTRIP, TIFFDefaultStripSize(tiff.get(), 0)))
      throw std::runtime_error("cannot configure SDR TIFF");
    const auto icc = gamut == ColorGamut::kSrgb ? codec::srgb_profile() : codec::display_p3_profile();
    if (!TIFFSetField(tiff.get(), TIFFTAG_ICCPROFILE,
                      static_cast<std::uint32_t>(icc.size()), icc.data()))
      throw std::runtime_error("cannot attach colour ICC to TIFF");
    if (!metadata.make.empty()) TIFFSetField(tiff.get(), TIFFTAG_MAKE, metadata.make.c_str());
    if (!metadata.model.empty()) TIFFSetField(tiff.get(), TIFFTAG_MODEL, metadata.model.c_str());
    if (!metadata.artist.empty()) TIFFSetField(tiff.get(), TIFFTAG_ARTIST, metadata.artist.c_str());
    if (!metadata.copyright.empty()) TIFFSetField(tiff.get(), TIFFTAG_COPYRIGHT, metadata.copyright.c_str());
    if (!metadata.date_time.empty()) TIFFSetField(tiff.get(), TIFFTAG_DATETIME, metadata.date_time.c_str());
    TIFFSetField(tiff.get(), TIFFTAG_SOFTWARE, "HyperDR");
    std::vector<std::uint16_t> row(static_cast<std::size_t>(image.width) * 3);
    for (std::uint32_t y = 0; y < image.height; ++y) {
      for (std::size_t x = 0; x < image.width; ++x) {
        const auto i = static_cast<std::size_t>(y) * row.size() + x * 3;
        auto color = fit_linear_p3_gamut(image.pixels[i], image.pixels[i+1], image.pixels[i+2],
                                         1.0F, gamut == ColorGamut::kSrgb);
        if (gamut == ColorGamut::kSrgb) color = linear_p3_to_rec709(color[0], color[1], color[2]);
        for (unsigned c = 0; c < 3; ++c) {
          const float encoded = srgb_oetf(std::clamp(color[c], 0.0F, 1.0F));
          row[x * 3 + c] = static_cast<std::uint16_t>(std::lround(encoded * 65535.0F));
        }
      }
      if (TIFFWriteScanline(tiff.get(), row.data(), y) < 0)
        throw std::runtime_error("SDR TIFF scanline encoding failed");
    }
  }
  return std::move(file.bytes);
}

void verify_sdr_tiff(const std::vector<std::uint8_t>& bytes) {
  const auto result = codec::decode_tiff_bytes(bytes, 0, ColorGamut::kSrgb);
  if (!result.linear_p3.width || !result.linear_p3.height || result.decode.resolution_reduced)
    throw std::runtime_error("SDR TIFF verification failed");
}

}  // namespace hyperdr
