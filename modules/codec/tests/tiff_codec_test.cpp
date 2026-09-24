#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <tiffio.h>

#include <cstdint>
#include <cmath>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void near(float actual, float expected, const char* message) {
  if (!std::isfinite(actual) || std::abs(actual - expected) > 0.003F)
    throw std::runtime_error(message);
}
struct TemporaryFile {
  std::filesystem::path path;
  ~TemporaryFile() { std::error_code error; std::filesystem::remove(path, error); }
};
}

int main() {
  using namespace hyperdr;
  const auto directory = std::filesystem::temp_directory_path();
  FloatImage original(2, 1, 3);
  original.pixels = {0.8F, 0.25F, 0.05F, 0.1F, 0.5F, 0.9F};
  PhotoMetadata metadata;
  metadata.make = "Sony";
  metadata.model = "Test camera";
  const auto bytes = encode_sdr_tiff(original, metadata);
  require(bytes.size() > 100, "empty SDR TIFF");
  verify_sdr_tiff(bytes);
  TemporaryFile rgb{directory / "hyperdr-tiff-rgb-test.tif"};
  write_binary_file_atomic(rgb.path, bytes, true);
  {
    TIFF* tiff = TIFFOpen(rgb.path.string().c_str(), "r");
    require(tiff != nullptr, "cannot inspect encoded TIFF");
    std::uint16_t bits = 0, photometric = 0;
    std::uint32_t icc_size = 0;
    void* icc = nullptr;
    require(TIFFGetField(tiff, TIFFTAG_BITSPERSAMPLE, &bits) && bits == 16,
            "SDR TIFF is not 16-bit");
    require(TIFFGetField(tiff, TIFFTAG_PHOTOMETRIC, &photometric) &&
            photometric == PHOTOMETRIC_RGB, "SDR TIFF is not RGB");
    require(TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &icc_size, &icc) &&
            icc_size > 100 && icc != nullptr, "SDR TIFF lacks Display P3 ICC");
    TIFFClose(tiff);
  }
  const auto decoded = decode_image(rgb.path);
  require(decoded.decode.target_width == 2 && decoded.decode.target_height == 1,
          "SDR TIFF geometry changed");
  require(decoded.metadata.make == metadata.make && decoded.metadata.model == metadata.model,
          "SDR TIFF camera metadata changed");
  require(decoded.hdr_headroom == 1.0F, "integer SDR TIFF advertised HDR");
  for (std::size_t i = 0; i < original.pixels.size(); ++i)
    near(decoded.linear_p3.pixels[i], original.pixels[i], "Display P3 TIFF round-trip changed colour");

  // A saturated P3 patch distinguishes a profile-only relabel from a real
  // conversion. Exercise both file formats through the ordinary ICC decoder.
  FloatImage patch(16, 16, 3);
  const std::array<float, 3> p3{0.05F, 0.8F, 0.03F};
  for (std::size_t i = 0; i < patch.pixels.size(); ++i) patch.pixels[i] = p3[i % 3];
  for (const bool jpeg : {false, true}) {
    for (const auto gamut : {ColorGamut::kSrgb, ColorGamut::kDisplayP3}) {
      TemporaryFile output{directory / (jpeg ? "hyperdr-gamut-output.jpg" : "hyperdr-gamut-output.tif")};
      const auto encoded = jpeg ? encode_sdr_jpeg(patch, {}, 100, gamut)
                                : encode_sdr_tiff(patch, {}, gamut);
      write_binary_file_atomic(output.path, encoded, true);
      const auto roundtrip = decode_image(output.path);
      const auto expected = gamut == ColorGamut::kSrgb
          ? compress_linear_p3_to_srgb(p3[0], p3[1], p3[2]) : p3;
      for (unsigned c = 0; c < 3; ++c)
        require(std::abs(roundtrip.linear_p3.at(8, 8, c) - expected[c]) < (jpeg ? .015F : .003F),
                "SDR output samples and embedded ICC disagree");
    }
  }

  TemporaryFile gray{directory / "hyperdr-tiff-gray-test.tiff"};
  {
    TIFF* tiff = TIFFOpen(gray.path.string().c_str(), "w");
    require(tiff != nullptr, "cannot create grayscale fixture");
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, 2);
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, 1);
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 1);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, 16);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISBLACK);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_ORIENTATION, ORIENTATION_RIGHTTOP);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    std::uint16_t row[]{0, 65535};
    require(TIFFWriteScanline(tiff, row, 0) >= 0, "cannot write grayscale fixture");
    TIFFClose(tiff);
  }
  const auto rotated = decode_image(gray.path);
  require(rotated.linear_p3.width == 1 && rotated.linear_p3.height == 2 &&
          rotated.metadata.orientation == 1, "TIFF Exif orientation was not applied");
  near(rotated.linear_p3.pixels[0], 0.0F, "grayscale black changed");
  near(rotated.linear_p3.pixels[3], 1.0F, "grayscale white changed");

  TemporaryFile gray8{directory / "hyperdr-tiff-gray8-test.tif"};
  {
    TIFF* tiff = TIFFOpen(gray8.path.string().c_str(), "w");
    require(tiff != nullptr, "cannot create 8-bit grayscale fixture");
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, 2);
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, 1);
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 1);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, 8);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISWHITE);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    std::uint8_t row[]{255, 0};
    require(TIFFWriteScanline(tiff, row, 0) >= 0, "cannot write 8-bit grayscale fixture");
    TIFFClose(tiff);
  }
  const auto gray8_decoded = decode_image(gray8.path);
  near(gray8_decoded.linear_p3.pixels[0], 0.0F, "8-bit white-is-zero black changed");
  near(gray8_decoded.linear_p3.pixels[3], 1.0F, "8-bit white-is-zero white changed");

  TemporaryFile cmyk{directory / "hyperdr-tiff-cmyk-test.tif"};
  {
    TIFF* tiff = TIFFOpen(cmyk.path.string().c_str(), "w");
    require(tiff != nullptr, "cannot create unsupported fixture");
    TIFFSetField(tiff, TIFFTAG_IMAGEWIDTH, 1);
    TIFFSetField(tiff, TIFFTAG_IMAGELENGTH, 1);
    TIFFSetField(tiff, TIFFTAG_SAMPLESPERPIXEL, 4);
    TIFFSetField(tiff, TIFFTAG_BITSPERSAMPLE, 8);
    TIFFSetField(tiff, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_SEPARATED);
    TIFFSetField(tiff, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
    TIFFSetField(tiff, TIFFTAG_COMPRESSION, COMPRESSION_NONE);
    std::uint8_t row[]{0, 0, 0, 0};
    require(TIFFWriteScanline(tiff, row, 0) >= 0, "cannot write CMYK fixture");
    TIFFClose(tiff);
  }
  bool rejected = false;
  try { (void)decode_image(cmyk.path); }
  catch (const std::runtime_error& error) {
    rejected = std::string(error.what()).find("unsigned 8/16-bit RGB or grayscale") !=
               std::string::npos;
  }
  require(rejected, "unsupported TIFF layout was not clearly rejected");
}
