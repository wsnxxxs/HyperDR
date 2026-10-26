#include "hyperdr/codec/raw_compat.hpp"

#include <tiffio.h>

#include <array>
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <memory>
#include <optional>
#include <stdexcept>
#include <vector>
#include <unistd.h>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
struct Close { void operator()(TIFF* tiff) const { if (tiff) TIFFClose(tiff); } };
using File = std::unique_ptr<TIFF, Close>;

void fixture(const std::filesystem::path& path, std::optional<float> black) {
  File tiff(TIFFOpen(path.c_str(), "wl"));
  require(bool(tiff), "cannot create test RAW");
  // A preview with unrelated calibration precedes the actual CFA sensor IFD.
  TIFFSetField(tiff.get(), TIFFTAG_IMAGEWIDTH, 8U);
  TIFFSetField(tiff.get(), TIFFTAG_IMAGELENGTH, 8U);
  TIFFSetField(tiff.get(), TIFFTAG_SAMPLESPERPIXEL, 3);
  TIFFSetField(tiff.get(), TIFFTAG_BITSPERSAMPLE, 8);
  TIFFSetField(tiff.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB);
  TIFFSetField(tiff.get(), TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  TIFFSetField(tiff.get(), TIFFTAG_MAKE, "Hasselblad");
  TIFFSetField(tiff.get(), TIFFTAG_MODEL, "L1D-20c");
  const float matrix[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
  const float neutral[3] = {1, 1, 1};
  TIFFSetField(tiff.get(), TIFFTAG_COLORMATRIX1, 9, matrix);
  TIFFSetField(tiff.get(), TIFFTAG_CALIBRATIONILLUMINANT1, 21);
  TIFFSetField(tiff.get(), TIFFTAG_ASSHOTNEUTRAL, 3, neutral);
  const float preview_black = 99;
  TIFFSetField(tiff.get(), TIFFTAG_BLACKLEVEL, 1, &preview_black);
  std::uint64_t subifd = 0;
  TIFFSetField(tiff.get(), TIFFTAG_SUBIFD, 1, &subifd);
  std::array<std::uint8_t, 24> thumbnail{};
  for (unsigned y = 0; y < 8; ++y) require(TIFFWriteScanline(tiff.get(), thumbnail.data(), y) >= 0, "preview write");
  require(TIFFWriteDirectory(tiff.get()), "preview directory");

  constexpr unsigned width = 256, height = 192;
  TIFFSetField(tiff.get(), TIFFTAG_IMAGEWIDTH, width);
  TIFFSetField(tiff.get(), TIFFTAG_IMAGELENGTH, height);
  TIFFSetField(tiff.get(), TIFFTAG_SAMPLESPERPIXEL, 1);
  TIFFSetField(tiff.get(), TIFFTAG_BITSPERSAMPLE, 16);
  TIFFSetField(tiff.get(), TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_CFA);
  TIFFSetField(tiff.get(), TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
  TIFFSetField(tiff.get(), TIFFTAG_COMPRESSION, COMPRESSION_NONE);
  TIFFSetField(tiff.get(), TIFFTAG_ROWSPERSTRIP, 16U);
  const std::uint16_t repeat[2] = {2, 2};
  const std::uint8_t pattern[4] = {0, 1, 1, 2};
  TIFFSetField(tiff.get(), TIFFTAG_CFAREPEATPATTERNDIM, repeat);
  TIFFSetField(tiff.get(), TIFFTAG_CFAPATTERN, 4, pattern);
  if (black) TIFFSetField(tiff.get(), TIFFTAG_BLACKLEVEL, 1, &*black);
  const std::uint32_t white = 65535;
  TIFFSetField(tiff.get(), TIFFTAG_WHITELEVEL, 1, &white);
  const std::uint32_t mask[4] = {0, 0, height, 16};
  TIFFSetField(tiff.get(), TIFFTAG_MASKEDAREAS, 4, mask);
  std::array<std::uint16_t, width> row{};
  row.fill(8192);
  std::fill_n(row.begin(), 16, 0);  // Phocus clears optical-black pixels only.
  for (unsigned y = 0; y < height; ++y) require(TIFFWriteScanline(tiff.get(), row.data(), y) >= 0, "RAW write");
  require(TIFFWriteDirectory(tiff.get()), "RAW directory");
}
}

int main() {
  std::string pattern = std::string(getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp") + "/hyperdr-black-XXXXXX";
  std::vector<char> name(pattern.begin(), pattern.end()); name.push_back(0);
  const char* directory = mkdtemp(name.data());
  require(directory, "cannot create test directory");
  const std::filesystem::path root(directory);
  struct Cleanup { std::filesystem::path path; ~Cleanup() { std::filesystem::remove_all(path); } } cleanup{root};
  // Non-default and fractional pedestals, plus a valid declared zero, must be
  // preserved. Without a declaration, keep LibRaw's ordinary estimate.
  for (const auto level : {std::optional<float>(4096), std::optional<float>(2048.5F),
                           std::optional<float>(0), std::optional<float>()}) {
    const auto raw = root / "sample.3FR", dng = root / "converted.dng";
    fixture(raw, level);
    static_cast<void>(hyperdr::raw_convert_dng(raw, dng));
    File tiff(TIFFOpen(dng.c_str(), "r"));
    require(bool(tiff), "cannot read converted DNG");
    std::uint16_t count = 0;
    float* values = nullptr;
    require(TIFFGetField(tiff.get(), TIFFTAG_BLACKLEVEL, &count, &values), "DNG lost black calibration");
    require(count == 4, "unexpected Bayer black pattern");
    for (unsigned i = 0; i < count; ++i) {
      const float expected = level.value_or(99);
      if (values[i] != expected) throw std::runtime_error("DNG black level: expected " +
          std::to_string(expected) + ", got " + std::to_string(values[i]));
    }
    std::filesystem::remove(raw); std::filesystem::remove(dng);
  }
}
