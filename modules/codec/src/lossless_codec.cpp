// The lossless formats beyond the 16-bit SDR TIFF (tiff_codec.cpp): a linear
// DNG of the SDR rendition, and the HDR rendition itself as IEEE float samples
// in TIFF or as 16-bit samples in a LinearRaw DNG.
//
// Float samples are linear light with SDR white at 1.0, the convention of an
// extended-range linear colour space and of Photoshop's 32-bit documents, so a
// highlight two stops above white is 4.0. Nothing is tone mapped, quantized to
// a transfer curve or split into a gain map: the file holds the rendition the
// gain map would have reconstructed at its full headroom.
//
// The HDR DNG is integer because Apple's raw engine develops no floating-point
// DNG (32-bit does not open; 16-bit develops black). Its samples are the same
// rendition divided by 2^headroom, so white sits at 65535 / 2^headroom, and
// BaselineExposure brings SDR white back to white when it is developed.

#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "internal/icc_profiles.hpp"
#include "internal/verify_pixels.hpp"

#include <tiffio.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

constexpr std::uint16_t kPhotometricLinearRaw = 34892;
// Classic TIFF and DNG address at most 4 GiB; a TIFF past this switches to
// BigTIFF, which DNG does not define.
constexpr std::uint64_t kClassicTiffLimit = 0xF0000000ULL;

struct TiffCloser {
  void operator()(TIFF* tiff) const { if (tiff) TIFFClose(tiff); }
};
using TiffHandle = std::unique_ptr<TIFF, TiffCloser>;

void require(int result, const char* what) {
  if (!result) throw std::runtime_error(std::string("cannot write ") + what);
}

struct Primaries {
  double red_x, red_y, green_x, green_y, blue_x, blue_y;
  const char* name;
};

Primaries primaries(ColorGamut gamut) {
  switch (gamut) {
    case ColorGamut::kSrgb: return {0.640, 0.330, 0.300, 0.600, 0.150, 0.060, "HyperDR Linear sRGB"};
    case ColorGamut::kDisplayP3: return {0.680, 0.320, 0.265, 0.690, 0.150, 0.060, "HyperDR Linear Display P3"};
    case ColorGamut::kRec2020: return {0.708, 0.292, 0.170, 0.797, 0.131, 0.046, "HyperDR Linear Rec. 2020"};
  }
  throw std::invalid_argument("unknown output gamut");
}

using Matrix = std::array<double, 9>;

Matrix inverse(const Matrix& m) {
  const double a = m[4] * m[8] - m[5] * m[7], b = m[5] * m[6] - m[3] * m[8], c = m[3] * m[7] - m[4] * m[6];
  const double determinant = m[0] * a + m[1] * b + m[2] * c;
  if (std::abs(determinant) < 1e-12) throw std::logic_error("singular colour matrix");
  const double k = 1.0 / determinant;
  return {a * k, (m[2] * m[7] - m[1] * m[8]) * k, (m[1] * m[5] - m[2] * m[4]) * k,
          b * k, (m[0] * m[8] - m[2] * m[6]) * k, (m[2] * m[3] - m[0] * m[5]) * k,
          c * k, (m[1] * m[6] - m[0] * m[7]) * k, (m[0] * m[4] - m[1] * m[3]) * k};
}

// DNG's ColorMatrix1 for a LinearRaw image whose "camera" is the linear RGB of
// `p`: XYZ (D65) to that RGB, the inverse of its RGB->XYZ matrix, so D65 white
// lands on (1, 1, 1) as the specification's normalization asks.
std::array<float, 9> xyz_to_rgb(const Primaries& p) {
  const auto xyz = [](double x, double y) { return std::array<double, 3>{x / y, 1.0, (1.0 - x - y) / y}; };
  const auto r = xyz(p.red_x, p.red_y), g = xyz(p.green_x, p.green_y), b = xyz(p.blue_x, p.blue_y);
  const auto w = xyz(0.3127, 0.3290);
  const Matrix columns{r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2]};
  const auto solve = inverse(columns);
  std::array<double, 3> scale{};
  for (unsigned i = 0; i < 3; ++i) scale[i] = solve[i * 3] * w[0] + solve[i * 3 + 1] * w[1] + solve[i * 3 + 2] * w[2];
  Matrix to_xyz{};
  for (unsigned row = 0; row < 3; ++row)
    for (unsigned column = 0; column < 3; ++column) to_xyz[row * 3 + column] = columns[row * 3 + column] * scale[column];
  const auto from_xyz = inverse(to_xyz);
  std::array<float, 9> out{};
  for (unsigned i = 0; i < 9; ++i) out[i] = static_cast<float>(from_xyz[i]);
  return out;
}

// Linear Display P3 (the planes' working space) to the output primaries,
// unclamped: a float file keeps a colour outside the target gamut as a
// negative component instead of moving it.
std::array<float, 3> from_linear_p3(ColorGamut gamut, float r, float g, float b) {
  switch (gamut) {
    case ColorGamut::kSrgb: return linear_p3_to_rec709(r, g, b);
    case ColorGamut::kDisplayP3: return {r, g, b};
    case ColorGamut::kRec2020: return p3_to_rec2020(r, g, b);
  }
  return {r, g, b};
}

// Bits per sample, and whether they are IEEE floats (the HDR TIFFs only).
unsigned sample_bits(OutputEncoding encoding) { return encoding == OutputEncoding::HdrTiff32 ? 32 : 16; }
bool float_samples(OutputEncoding encoding) { return is_linear_hdr_encoding(encoding) && !is_dng_encoding(encoding); }

void common_tags(TIFF* tiff, std::uint32_t width, std::uint32_t height, const PhotoMetadata& metadata, bool dng) {
  require(TIFFSetField(tiff, TIFFTAG_SUBFILETYPE, 0U), "TIFF subfile type");
  require(TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, width), "TIFF width");
  require(TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, height), "TIFF height");
  require(TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 3), "TIFF samples");
  require(TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG), "TIFF planar layout");
  // The planes are upright; the tag must not rotate them again.
  require(TIFFSetField(tiff, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT), "TIFF orientation");
  if (!dng && !metadata.make.empty()) TIFFSetField(tiff, TIFFTAG_MAKE, metadata.make.c_str());
  if (!dng && !metadata.model.empty()) TIFFSetField(tiff, TIFFTAG_MODEL, metadata.model.c_str());
  if (!metadata.artist.empty()) TIFFSetField(tiff, TIFFTAG_ARTIST, metadata.artist.c_str());
  if (!metadata.copyright.empty()) TIFFSetField(tiff, TIFFTAG_COPYRIGHT, metadata.copyright.c_str());
  if (!metadata.date_time.empty()) TIFFSetField(tiff, TIFFTAG_DATETIME, metadata.date_time.c_str());
  TIFFSetField(tiff, TIFFTAG_SOFTWARE, "HyperDR");
}

// LinearRaw with the output RGB as its "camera": the colour matrix says what
// that RGB is, the neutral is its white, and an identity tone curve keeps a raw
// developer from adding its own contrast to a rendition that already has it.
// An HDR file is scaled so its headroom fits under white, and BaselineExposure
// raises it back: SDR white develops to white, and the highlights stay above.
// DNG 1.2+ tags libtiff's own table does not list; it writes them once told
// their types.
void register_dng_fields(TIFF* tiff) {
  static TIFFFieldInfo fields[] = {
      {TIFFTAG_PROFILENAME, -1, -1, TIFF_ASCII, FIELD_CUSTOM, 1, 0, const_cast<char*>("ProfileName")},
      {TIFFTAG_PROFILETONECURVE, -1, -1, TIFF_FLOAT, FIELD_CUSTOM, 1, 1, const_cast<char*>("ProfileToneCurve")},
      {TIFFTAG_PROFILEEMBEDPOLICY, 1, 1, TIFF_LONG, FIELD_CUSTOM, 1, 0, const_cast<char*>("ProfileEmbedPolicy")},
      {TIFFTAG_DEFAULTBLACKRENDER, 1, 1, TIFF_LONG, FIELD_CUSTOM, 1, 0, const_cast<char*>("DefaultBlackRender")},
  };
  for (auto& field : fields)
    if (!TIFFFindField(tiff, field.field_tag, TIFF_ANY))
      require(TIFFMergeFieldInfo(tiff, &field, 1) == 0, "DNG field definitions");
}

void dng_tags(TIFF* tiff, std::uint32_t width, std::uint32_t height, ColorGamut gamut, float baseline_stops) {
  register_dng_fields(tiff);
  const std::uint32_t active[4] = {0, 0, height, width};
  const float origin[2] = {0, 0}, size[2] = {float(width), float(height)}, unit[2] = {1, 1};
  require(TIFFSetField(tiff, TIFFTAG_ACTIVEAREA, active), "DNG active area");
  require(TIFFSetField(tiff, TIFFTAG_DEFAULTCROPORIGIN, origin), "DNG crop origin");
  require(TIFFSetField(tiff, TIFFTAG_DEFAULTCROPSIZE, size), "DNG crop size");
  require(TIFFSetField(tiff, TIFFTAG_DEFAULTSCALE, unit), "DNG scale");
  const std::uint8_t version[4] = {1, 4, 0, 0}, backward[4] = {1, 4, 0, 0};
  require(TIFFSetField(tiff, TIFFTAG_DNGVERSION, version), "DNG version");
  require(TIFFSetField(tiff, TIFFTAG_DNGBACKWARDVERSION, backward), "DNG backward version");
  const auto p = primaries(gamut);
  require(TIFFSetField(tiff, TIFFTAG_UNIQUECAMERAMODEL, p.name), "DNG camera model");
  // A raw reader keys camera-specific processing on Make and Model; these name
  // no camera, so the colour matrix above is what develops the file.
  require(TIFFSetField(tiff, TIFFTAG_MAKE, "HyperDR"), "DNG make");
  require(TIFFSetField(tiff, TIFFTAG_MODEL, p.name), "DNG model");
  const auto matrix = xyz_to_rgb(p);
  require(TIFFSetField(tiff, TIFFTAG_COLORMATRIX1, 9, matrix.data()), "DNG colour matrix");
  require(TIFFSetField(tiff, TIFFTAG_CALIBRATIONILLUMINANT1, 21), "DNG illuminant");  // D65
  const float neutral[3] = {1.0F, 1.0F, 1.0F};
  require(TIFFSetField(tiff, TIFFTAG_ASSHOTNEUTRAL, 3, neutral), "DNG neutral");
  require(TIFFSetField(tiff, TIFFTAG_BASELINEEXPOSURE, static_cast<double>(baseline_stops)), "DNG baseline exposure");
  const float curve[4] = {0.0F, 0.0F, 1.0F, 1.0F};
  require(TIFFSetField(tiff, TIFFTAG_PROFILETONECURVE, 4, curve), "DNG tone curve");
  require(TIFFSetField(tiff, TIFFTAG_PROFILENAME, p.name), "DNG profile name");
  require(TIFFSetField(tiff, TIFFTAG_PROFILEEMBEDPOLICY, 3U), "DNG profile policy");  // no restrictions
  require(TIFFSetField(tiff, TIFFTAG_DEFAULTBLACKRENDER, 1U), "DNG black render");    // none
  const float black[3] = {0, 0, 0};
  require(TIFFSetField(tiff, TIFFTAG_BLACKLEVEL, 3, black), "DNG black level");
}

// The capture facts a photo editor shows, in an Exif IFD. Raw readers also
// look for one before they accept a DNG.
void write_exif_ifd(TIFF* tiff, const PhotoMetadata& metadata) {
  require(TIFFCreateEXIFDirectory(tiff) == 0, "Exif directory");
  const std::uint8_t version[4] = {'0', '2', '3', '2'};
  require(TIFFSetField(tiff, EXIFTAG_EXIFVERSION, version), "Exif version");
  if (!metadata.date_time.empty()) TIFFSetField(tiff, EXIFTAG_DATETIMEORIGINAL, metadata.date_time.c_str());
  if (metadata.iso > 0) {
    const std::uint16_t iso[1] = {static_cast<std::uint16_t>(std::min<std::uint32_t>(65535, metadata.iso))};
    TIFFSetField(tiff, EXIFTAG_ISOSPEEDRATINGS, 1, iso);
  }
  if (metadata.exposure_seconds > 0) TIFFSetField(tiff, EXIFTAG_EXPOSURETIME, metadata.exposure_seconds);
  if (metadata.aperture > 0) TIFFSetField(tiff, EXIFTAG_FNUMBER, metadata.aperture);
  if (metadata.focal_length_mm > 0) TIFFSetField(tiff, EXIFTAG_FOCALLENGTH, metadata.focal_length_mm);
  if (metadata.focal_length_35mm > 0)
    TIFFSetField(tiff, EXIFTAG_FOCALLENGTHIN35MMFILM,
                 static_cast<std::uint16_t>(std::clamp(std::lround(metadata.focal_length_35mm), 1L, 65535L)));
  if (!metadata.lens_make.empty()) TIFFSetField(tiff, EXIFTAG_LENSMAKE, metadata.lens_make.c_str());
  if (!metadata.lens.empty()) TIFFSetField(tiff, EXIFTAG_LENSMODEL, metadata.lens.c_str());
}

void finish(TiffHandle& tiff, const PhotoMetadata& metadata, const char* what) {
  // The image directory first, then the Exif directory it points to, then the
  // image directory again with that pointer.
  std::uint64_t exif = 0;
  if (!TIFFWriteDirectory(tiff.get())) throw std::runtime_error(std::string(what) + " directory failed");
  write_exif_ifd(tiff.get(), metadata);
  if (!TIFFWriteCustomDirectory(tiff.get(), &exif) || !TIFFSetDirectory(tiff.get(), 0) ||
      !TIFFSetField(tiff.get(), TIFFTAG_EXIFIFD, exif))
    throw std::runtime_error(std::string(what) + " Exif directory failed");
  // TIFFClose cannot report failure. Commit the final strip and IFD while
  // failures can still prevent publication, then close the owned fd explicitly.
  if (!TIFFWriteDirectory(tiff.get()) || !TIFFFlush(tiff.get()))
    throw std::runtime_error(std::string(what) + " finalization failed");
  const int fd = TIFFFileno(tiff.get());
  TIFFCleanup(tiff.release());
  if (::close(fd) != 0) throw std::runtime_error(std::string(what) + " close failed");
}

}  // namespace

void write_lossless_rows(const EncodingRows& base, const LinearHdrGain* hdr, const PhotoMetadata& metadata,
                         OutputEncoding encoding, ColorGamut gamut, const std::filesystem::path& path) {
  if (encoding != OutputEncoding::SdrDng && !is_linear_hdr_encoding(encoding))
    throw std::invalid_argument("not a float or DNG lossless encoding");
  if (base.channels != 3) throw std::invalid_argument("lossless export requires RGB pixels");
  const bool linear_hdr = is_linear_hdr_encoding(encoding), dng = is_dng_encoding(encoding);
  if (linear_hdr && hdr == nullptr) throw std::invalid_argument("an HDR rendition needs the gain plane");
  if (hdr && (hdr->gain.width != base.width || hdr->gain.height != base.height ||
              (hdr->gain.channels != 1 && hdr->gain.channels != 3)))
    throw std::invalid_argument("the gain rows must match the base, with one or three channels");
  const unsigned bits = sample_bits(encoding);
  const bool floats = float_samples(encoding);
  const std::uint64_t bytes = std::uint64_t(base.width) * base.height * 3 * (bits / 8);
  if (dng && bytes > kClassicTiffLimit)
    throw std::runtime_error("DNG " + std::to_string(base.width) + "x" + std::to_string(base.height) +
                             " exceeds the 4 GB a DNG file can address");

  // The HDR DNG keeps its samples under the white level; BaselineExposure
  // restores the brightness.
  const float headroom = linear_hdr && hdr ? std::max(0.0F, hdr->headroom_stops) : 0.0F;
  const float baseline = dng && linear_hdr ? headroom : 0.0F;
  const float scale = std::exp2(-baseline);

  TiffHandle tiff(TIFFOpen(path.c_str(), !dng && bytes > kClassicTiffLimit ? "w8" : "wl"));
  if (!tiff) throw std::runtime_error("cannot open lossless output");
  common_tags(tiff.get(), base.width, base.height, metadata, dng);
  require(TIFFSetField(tiff.get(), TIFFTAG_BITSPERSAMPLE, bits), "TIFF bit depth");
  require(TIFFSetField(tiff.get(), TIFFTAG_SAMPLEFORMAT, floats ? SAMPLEFORMAT_IEEEFP : SAMPLEFORMAT_UINT),
          "TIFF sample format");
  if (dng) {
    require(TIFFSetField(tiff.get(), TIFFTAG_PHOTOMETRIC, kPhotometricLinearRaw), "DNG photometric");
    require(TIFFSetField(tiff.get(), TIFFTAG_COMPRESSION, COMPRESSION_NONE), "DNG compression");
    require(TIFFSetField(tiff.get(), TIFFTAG_ROWSPERSTRIP, 16U), "DNG strips");
    dng_tags(tiff.get(), base.width, base.height, gamut, baseline);
    const std::uint32_t white[3] = {65535, 65535, 65535};
    require(TIFFSetField(tiff.get(), TIFFTAG_WHITELEVEL, 3, white), "DNG white level");
  } else {
    require(TIFFSetField(tiff.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB), "TIFF photometric");
    require(TIFFSetField(tiff.get(), TIFFTAG_COMPRESSION, COMPRESSION_ADOBE_DEFLATE), "TIFF compression");
    require(TIFFSetField(tiff.get(), TIFFTAG_PREDICTOR, PREDICTOR_FLOATINGPOINT), "TIFF predictor");
    require(TIFFSetField(tiff.get(), TIFFTAG_ROWSPERSTRIP, TIFFDefaultStripSize(tiff.get(), 0)), "TIFF strips");
    const auto p = primaries(gamut);
    const auto icc = codec::linear_rgb_profile(p.red_x, p.red_y, p.green_x, p.green_y, p.blue_x, p.blue_y, p.name);
    require(TIFFSetField(tiff.get(), TIFFTAG_ICCPROFILE, static_cast<std::uint32_t>(icc.size()), icc.data()),
            "TIFF colour profile");
  }

  const std::size_t stride = std::size_t(base.width) * 3;
  std::vector<float> linear(stride), gain(hdr ? std::size_t(base.width) * hdr->gain.channels : 0);
  std::vector<std::uint8_t> row(stride * (bits / 8));
  for (std::uint32_t y = 0; y < base.height; ++y) {
    check_cancelled();
    base.read(y, linear);
    if (linear_hdr) hdr->gain.read(y, gain);
    const unsigned channels = hdr ? hdr->gain.channels : 0;
    for (std::uint32_t x = 0; x < base.width; ++x) {
      const auto i = std::size_t(x) * 3;
      std::array<float, 3> color{linear[i], linear[i + 1], linear[i + 2]};
      if (linear_hdr) {
        // The alternate rendition at its full headroom, as the gain map defines it.
        for (unsigned c = 0; c < 3; ++c) {
          const float stops = gain[std::size_t(x) * channels + (channels == 1 ? 0 : c)];
          color[c] = (color[c] + hdr->base_offset[c]) * std::exp2(stops) - hdr->alternate_offset[c];
        }
        color = from_linear_p3(gamut, color[0], color[1], color[2]);
        // A raw developer has no use for light below black.
        if (dng) for (auto& v : color) v = std::max(0.0F, v) * scale;
      } else {
        if (gamut == ColorGamut::kSrgb) color = compress_linear_p3_to_srgb(color[0], color[1], color[2]);
        color = fit_linear_p3_gamut(color[0], color[1], color[2], 1.0F, gamut == ColorGamut::kSrgb);
        color = from_linear_p3(gamut, color[0], color[1], color[2]);
      }
      for (unsigned c = 0; c < 3; ++c) {
        const float value = color[c];
        if (!std::isfinite(value)) throw std::invalid_argument("lossless export met a non-finite sample");
        auto* target = row.data() + (i + c) * (bits / 8);
        if (!floats) {
          const auto code = static_cast<std::uint16_t>(std::lround(std::clamp(value, 0.0F, 1.0F) * 65535.0F));
          std::memcpy(target, &code, 2);
        } else if (bits == 16) {
          // Half floats top out at 65504; anything brighter is not a photograph.
          const auto half = static_cast<_Float16>(std::clamp(value, -65504.0F, 65504.0F));
          std::memcpy(target, &half, 2);
        } else {
          std::memcpy(target, &value, 4);
        }
      }
    }
    if (TIFFWriteScanline(tiff.get(), row.data(), y) < 0)
      throw std::runtime_error("lossless scanline encoding failed");
  }
  finish(tiff, metadata, dng ? "DNG" : "float TIFF");
}

namespace codec {
namespace {

struct ReadFile {
  std::span<const std::uint8_t> bytes;
  std::uint64_t position{};
};

tmsize_t read_bytes(thandle_t handle, void* destination, tmsize_t count) {
  auto& file = *static_cast<ReadFile*>(handle);
  if (count <= 0 || file.position >= file.bytes.size()) return 0;
  const auto size = std::min<std::size_t>(file.bytes.size() - file.position, std::size_t(count));
  std::memcpy(destination, file.bytes.data() + file.position, size);
  file.position += size;
  return tmsize_t(size);
}
tmsize_t write_none(thandle_t, void*, tmsize_t) { return 0; }
toff_t seek_bytes(thandle_t handle, toff_t offset, int origin) {
  auto& file = *static_cast<ReadFile*>(handle);
  const std::int64_t base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? std::int64_t(file.position)
      : origin == SEEK_END ? std::int64_t(file.bytes.size()) : -1;
  const auto target = base + std::int64_t(offset);
  if (base < 0 || target < 0) return toff_t(-1);
  file.position = std::uint64_t(target);
  return toff_t(file.position);
}
int close_none(thandle_t) { return 0; }
toff_t size_bytes(thandle_t handle) { return toff_t(static_cast<ReadFile*>(handle)->bytes.size()); }
int map_none(thandle_t, void**, toff_t*) { return 0; }
void unmap_none(thandle_t, void*, toff_t) {}

}  // namespace

// Reads every scanline back in the layout the writer promised and checks each
// sample is a number. The colour is the writer's own arithmetic; what this
// proves is that a TIFF reader finds the file it was meant to.
VerificationResult verify_lossless_pixels(std::span<const std::uint8_t> bytes, OutputEncoding encoding) {
  ReadFile file{bytes};
  TiffHandle tiff(TIFFClientOpen("HyperDR lossless", "rm", &file, read_bytes, write_none, seek_bytes,
                                 close_none, size_bytes, map_none, unmap_none));
  if (!tiff) throw std::runtime_error("cannot open the written lossless file");
  std::uint32_t width = 0, height = 0;
  std::uint16_t bits = 0, samples = 0, photometric = 0, planar = 0, format = 0;
  if (!TIFFGetField(tiff.get(), TIFFTAG_IMAGEWIDTH, &width) || !TIFFGetField(tiff.get(), TIFFTAG_IMAGELENGTH, &height))
    throw std::runtime_error("lossless file has no image dimensions");
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_BITSPERSAMPLE, &bits);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_SAMPLESPERPIXEL, &samples);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_PHOTOMETRIC, &photometric);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_PLANARCONFIG, &planar);
  TIFFGetFieldDefaulted(tiff.get(), TIFFTAG_SAMPLEFORMAT, &format);
  const bool floats = float_samples(encoding), dng = is_dng_encoding(encoding);
  if (!width || !height || samples != 3 || planar != PLANARCONFIG_CONTIG || bits != sample_bits(encoding) ||
      format != (floats ? SAMPLEFORMAT_IEEEFP : SAMPLEFORMAT_UINT) ||
      photometric != (dng ? kPhotometricLinearRaw : PHOTOMETRIC_RGB))
    throw std::runtime_error("the lossless file does not have the layout its writer promised");
  if (dng) {
    void* version = nullptr;
    if (!TIFFGetField(tiff.get(), TIFFTAG_DNGVERSION, &version) || !version)
      throw std::runtime_error("the DNG has no DNG version");
  }
  const auto stride = std::size_t(width) * 3 * (bits / 8);
  if (TIFFScanlineSize(tiff.get()) != tmsize_t(stride)) throw std::runtime_error("unsupported lossless scanline layout");
  std::vector<std::uint8_t> row(stride);
  std::vector<float> linear(std::size_t(width) * 3);
  VerificationPixels check(width, height, {});
  for (std::uint32_t y = 0; y < height; ++y) {
    check_cancelled();
    if (TIFFReadScanline(tiff.get(), row.data(), y) < 0) throw std::runtime_error("lossless scanline decode failed");
    for (std::size_t i = 0; i < linear.size(); ++i) {
      if (!floats) {
        std::uint16_t code = 0;
        std::memcpy(&code, row.data() + i * 2, 2);
        linear[i] = code / 65535.0F;
      } else if (bits == 16) {
        _Float16 half{};
        std::memcpy(&half, row.data() + i * 2, 2);
        linear[i] = static_cast<float>(half);
      } else {
        std::memcpy(&linear[i], row.data() + i * 4, 4);
      }
    }
    check.row(0, y, linear);
  }
  return check.result;
}

}  // namespace codec
}  // namespace hyperdr
