// The lossless DNG and float TIFF formats through the C ABI: both packaging
// entries write the same samples, the samples are the HDR rendition the pair
// reconstructs (or the SDR base), and the files carry the layout and tags a
// TIFF or DNG reader needs.
#include "hyperdr/hyperdr.h"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"

#include <tiffio.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <tuple>
#include <vector>

#include <unistd.h>

#define REQUIRE(x) do { if(!(x)) throw std::runtime_error(std::string("line ") + std::to_string(__LINE__) + ": " #x); } while(0)

namespace {

struct Source {
  unsigned width = 37, height = 29, channels = 1;
  unsigned reads = 0, largest = 0;
  float base_value(unsigned x, unsigned y, unsigned c) const {
    const float u = float(x) / float(width - 1), v = float(y) / float(height - 1);
    return c == 0 ? .05f + .9f * u : c == 1 ? .1f + .8f * v : .2f + .3f * u * v;
  }
  // Signed stops, up to 3 above SDR white, so the HDR rendition has values
  // well above 1.0 and some below the base.
  float gain_value(unsigned x, unsigned y, unsigned c) const {
    const float u = float(x) / float(width - 1), v = float(y) / float(height - 1);
    return -.5f + 3.5f * u * v - (channels == 3 ? .2f * float(c) : 0.f);
  }
  static int read(void* context, unsigned y, unsigned count, float* base, float* gain) {
    auto& s = *static_cast<Source*>(context);
    ++s.reads;
    s.largest = std::max(s.largest, count);
    for (unsigned row = 0; row < count; ++row)
      for (unsigned x = 0; x < s.width; ++x) {
        const auto i = std::size_t(row) * s.width + x;
        for (unsigned c = 0; c < 3; ++c) base[i * 3 + c] = s.base_value(x, y + row, c);
        if (gain) for (unsigned c = 0; c < s.channels; ++c) gain[i * s.channels + c] = s.gain_value(x, y + row, c);
      }
    return 0;
  }
};

void status(int code, char* report, hyperdr_error* error) {
  if (code) {
    const std::string message = error ? std::string(error->code) + ": " + error->message : "missing error";
    hyperdr_error_free(error);
    hyperdr_string_free(report);
    throw std::runtime_error(message);
  }
  REQUIRE(report && std::strstr(report, "hyperdr.package/v1"));
  hyperdr_string_free(report);
  hyperdr_error_free(error);
}

struct ReadBack {
  unsigned width = 0, height = 0, bits = 0, format = 0, photometric = 0;
  double baseline = 0;
  bool dng = false, icc = false;
  std::vector<float> samples;
};

ReadBack read_back(const std::filesystem::path& path) {
  ReadBack out;
  TIFF* tiff = TIFFOpen(path.c_str(), "r");
  REQUIRE(tiff);
  std::uint32_t width = 0, height = 0;
  std::uint16_t bits = 0, format = 0, photometric = 0;
  TIFFGetField(tiff, TIFFTAG_IMAGEWIDTH, &width);
  TIFFGetField(tiff, TIFFTAG_IMAGELENGTH, &height);
  TIFFGetFieldDefaulted(tiff, TIFFTAG_BITSPERSAMPLE, &bits);
  TIFFGetFieldDefaulted(tiff, TIFFTAG_SAMPLEFORMAT, &format);
  TIFFGetFieldDefaulted(tiff, TIFFTAG_PHOTOMETRIC, &photometric);
  out.width = width; out.height = height; out.bits = bits; out.format = format; out.photometric = photometric;
  void* version = nullptr;
  out.dng = TIFFGetField(tiff, TIFFTAG_DNGVERSION, &version) && version;
  // libtiff hands a rational back as float or double, as its table says.
  if (const auto* field = TIFFFindField(tiff, TIFFTAG_BASELINEEXPOSURE, TIFF_ANY)) {
    if (TIFFFieldSetGetSize(field) == 4) {
      float baseline = 0;
      if (TIFFGetField(tiff, TIFFTAG_BASELINEEXPOSURE, &baseline)) out.baseline = baseline;
    } else {
      double baseline = 0;
      if (TIFFGetField(tiff, TIFFTAG_BASELINEEXPOSURE, &baseline)) out.baseline = baseline;
    }
  }
  std::uint32_t icc_size = 0; void* icc = nullptr;
  out.icc = TIFFGetField(tiff, TIFFTAG_ICCPROFILE, &icc_size, &icc) && icc_size;
  std::vector<std::uint8_t> row(TIFFScanlineSize(tiff));
  out.samples.reserve(std::size_t(width) * height * 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    REQUIRE(TIFFReadScanline(tiff, row.data(), y) >= 0);
    for (std::size_t i = 0; i < std::size_t(width) * 3; ++i) {
      if (format == SAMPLEFORMAT_UINT) {
        std::uint16_t code; std::memcpy(&code, row.data() + i * 2, 2); out.samples.push_back(code / 65535.f);
      } else if (bits == 16) {
        _Float16 half; std::memcpy(&half, row.data() + i * 2, 2); out.samples.push_back(float(half));
      } else {
        float value; std::memcpy(&value, row.data() + i * 4, 4); out.samples.push_back(value);
      }
    }
  }
  TIFFClose(tiff);
  return out;
}

}  // namespace

int main() try {
  auto directory = (std::filesystem::temp_directory_path() / "hyperdr-package-lossless-XXXXXX").native();
  REQUIRE(mkdtemp(directory.data()));
  const std::filesystem::path root(directory);
  const auto whole = root / "whole", stream = root / "stream";
  hyperdr_engine* engine = nullptr; hyperdr_error* error = nullptr;
  REQUIRE(hyperdr_engine_create(nullptr, &engine, &error) == 0);

  Source source;
  hyperdr_package_plane base{}; base.width = source.width; base.height = source.height; base.channels = 3;
  base.format = HYPERDR_PLANE_F32;
  hyperdr_package_gain gain{}; gain.plane = base; gain.working_gamut = "display-p3"; gain.alternate_headroom = 3;
  hyperdr_package_request request{}; request.sdr = &base;

  struct Case { const char* format; const char* gamut; unsigned channels; };
  const Case cases[] = {
      {"hdr-tiff-32", "p3", 1}, {"hdr-tiff-32", "rec2020", 3}, {"hdr-tiff-16", "srgb", 1},
      {"hdr-dng", "p3", 3}, {"hdr-dng", "rec2020", 1}, {"sdr-dng", "p3", 0}, {"sdr-dng", "rec2020", 0}};
  for (const auto& test : cases) {
    const std::string format = test.format;
    const auto encoding = *hyperdr::hdr_encoding_from_name(format);
    const bool hdr = hyperdr::is_linear_hdr_encoding(encoding), dng = hyperdr::is_dng_encoding(encoding);
    const bool floats = hdr && !dng;
    const auto gamut = *hyperdr::color_gamut_from_name(test.gamut);
    REQUIRE(hyperdr_package_rows_supported(test.format));
    source.channels = test.channels ? test.channels : 1;
    gain.plane.channels = source.channels;
    for (unsigned c = 0; c < 3; ++c) {
      gain.base_offset[c] = hdr ? .01f + .001f * float(c) : 0.f;
      gain.alternate_offset[c] = hdr ? .02f - .002f * float(c) : 0.f;
    }
    std::vector<float> b(std::size_t(source.width) * source.height * 3),
        g(std::size_t(source.width) * source.height * source.channels);
    Source::read(&source, 0, source.height, b.data(), g.data());
    base.data = b.data(); base.size = b.size() * 4;
    gain.plane.data = g.data(); gain.plane.size = g.size() * 4;
    request.format = test.format;
    request.gain = hdr ? &gain : nullptr;
    const auto parameters = std::string("{\"gamut\":\"") + test.gamut + "\",\"overwrite\":true}";
    request.parameters_json = parameters.c_str();

    const auto whole_path = whole.string(), stream_path = stream.string();
    request.output_path = whole_path.c_str();
    char* report = nullptr; error = nullptr;
    status(hyperdr_package(engine, &request, &report, &error), report, error);
    request.output_path = stream_path.c_str(); report = nullptr; error = nullptr;
    source.reads = source.largest = 0;
    status(hyperdr_package_rows(engine, &request, 8, Source::read, &source, &report, &error), report, error);
    // One pass: the float writers need no codebook scan or replay.
    REQUIRE(source.largest <= 8 && source.reads == (source.height + 7) / 8);

    const auto a = read_back(whole), r = read_back(stream);
    REQUIRE(a.samples == r.samples);
    REQUIRE(r.width == source.width && r.height == source.height);
    REQUIRE(r.dng == dng && r.icc == !dng);
    REQUIRE(r.photometric == (dng ? 34892U : unsigned(PHOTOMETRIC_RGB)));
    REQUIRE(r.format == (floats ? unsigned(SAMPLEFORMAT_IEEEFP) : unsigned(SAMPLEFORMAT_UINT)));
    REQUIRE(r.bits == (format.ends_with("-32") ? 32U : 16U));
    const float stops = dng && hdr ? gain.alternate_headroom : 0.f;
    REQUIRE(std::abs(r.baseline - stops) < 1e-6);
    (void)hyperdr::verify_encoded_file(stream, encoding);

    float worst = 0, brightest = 0;
    for (unsigned y = 0; y < source.height; ++y)
      for (unsigned x = 0; x < source.width; ++x) {
        std::array<float, 3> expected{};
        for (unsigned c = 0; c < 3; ++c) {
          const float sdr = source.base_value(x, y, c);
          // A one-channel map has one offset pair, the first (ISO 21496-1).
          const unsigned k = source.channels == 1 ? 0 : c;
          expected[c] = hdr ? (sdr + gain.base_offset[k]) * std::exp2(source.gain_value(x, y, k))
                                  - gain.alternate_offset[k] : sdr;
        }
        expected = gamut == hyperdr::ColorGamut::kSrgb ? hyperdr::linear_p3_to_rec709(expected[0], expected[1], expected[2])
                 : gamut == hyperdr::ColorGamut::kRec2020 ? hyperdr::p3_to_rec2020(expected[0], expected[1], expected[2])
                 : expected;
        for (unsigned c = 0; c < 3; ++c) {
          float want = expected[c];
          if (dng && hdr) want = std::max(0.f, want) * std::exp2(-stops);
          if (!floats) want = std::clamp(want, 0.f, 1.f);
          const float got = r.samples[(std::size_t(y) * source.width + x) * 3 + c];
          const float tolerance = !floats ? 1.f / 65535 : r.bits == 16 ? std::abs(want) * 1e-3f + 1e-4f : 1e-6f * (1 + std::abs(want));
          worst = std::max(worst, std::abs(got - want) - tolerance);
          brightest = std::max(brightest, got);
        }
      }
    REQUIRE(worst <= 0);
    // The float TIFF keeps highlights above SDR white; the DNG scales them under it.
    if (hdr && !dng) REQUIRE(brightest > 4.f);
    if (dng) REQUIRE(brightest <= 1.f + 1e-6f);
    std::cout << format << ' ' << test.gamut << " channels=" << test.channels << " brightest=" << brightest << '\n';
    std::filesystem::remove(whole); std::filesystem::remove(stream);
  }

  // A float file is the HDR rendition: without a gain plane there is none.
  // Rec. 2020 belongs to the lossless formats only.
  {
    const auto path = stream.string();
    request.output_path = path.c_str();
    for (const auto& [format, parameters, with_gain] : {
             std::tuple{"hdr-tiff-32", "{}", false}, std::tuple{"sdr-jpeg", "{\"gamut\":\"rec2020\"}", false},
             std::tuple{"adaptive", "{\"gamut\":\"rec2020\"}", true}}) {
      request.format = format; request.parameters_json = parameters;
      request.gain = with_gain ? &gain : nullptr;
      char* report = nullptr; error = nullptr;
      REQUIRE(hyperdr_package_rows(engine, &request, 8, Source::read, &source, &report, &error) != 0);
      hyperdr_error_free(error); hyperdr_string_free(report);
      REQUIRE(!std::filesystem::exists(stream));
    }
  }
  hyperdr_engine_destroy(engine);
  for (const auto& entry : std::filesystem::directory_iterator(root))
    throw std::runtime_error("staging file leaked: " + entry.path().string());
  std::filesystem::remove_all(root);
  return 0;
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}
