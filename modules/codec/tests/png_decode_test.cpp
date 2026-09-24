#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"

#include <lcms2.h>
#include <png.h>

#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void near(float actual, float expected, const char* message) {
  if (!std::isfinite(actual) || std::abs(actual - expected) > 3e-4F) {
    std::cerr << message << ": " << actual << " expected " << expected << '\n';
    throw std::runtime_error(message);
  }
}
struct Fixture {
  unsigned width{1}, height{1};
  int bits{8};
  int transfer{};
  bool srgb{}, p3_chrm{}, icc{}, interlaced{}, gray{}, narrow{}, alpha{}, palette{};
  double gamma{};
  std::optional<png_uint_32> content_peak;
  std::vector<unsigned char> pixels{128, 128, 128};
};
void write_bytes(png_structp png, png_bytep data, png_size_t size) {
  auto& bytes = *static_cast<std::vector<unsigned char>*>(png_get_io_ptr(png));
  bytes.insert(bytes.end(), data, data + size);
}
std::vector<unsigned char> encode(const Fixture& f) {
  std::vector<unsigned char> bytes;
  auto* png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, nullptr);
  auto* info = png_create_info_struct(png);
  png_set_write_fn(png, &bytes, write_bytes, nullptr);
  const int type = f.palette ? PNG_COLOR_TYPE_PALETTE
      : (f.gray ? PNG_COLOR_TYPE_GRAY : PNG_COLOR_TYPE_RGB) | (f.alpha ? PNG_COLOR_MASK_ALPHA : 0);
  png_set_IHDR(png, info, f.width, f.height, f.bits, type,
               f.interlaced ? PNG_INTERLACE_ADAM7 : PNG_INTERLACE_NONE, 0, 0);
  if (f.palette) {
    png_color palette[2]{{255, 0, 0}, {0, 0, 255}};
    png_byte transparency[2]{0, 255};
    png_set_PLTE(png, info, palette, 2);
    png_set_tRNS(png, info, transparency, 2, nullptr);
  }
  if (f.gamma) png_set_gAMA(png, info, f.gamma);
  if (f.content_peak) png_set_cLLI_fixed(png, info, *f.content_peak, 0);
  if (f.p3_chrm) png_set_cHRM(png, info, .3127, .3290, .680, .320, .265, .690, .150, .060);
  if (f.srgb) png_set_sRGB(png, info, PNG_sRGB_INTENT_RELATIVE);
  if (f.icc) {
    auto profile = cmsCreate_sRGBProfile();
    if (f.gray) {
      cmsCloseProfile(profile);
      cmsCIExyY white{.3127, .3290, 1};
      auto* curve = cmsBuildGamma(nullptr, 1);
      profile = cmsCreateGrayProfile(&white, curve);
      cmsFreeToneCurve(curve);
    }
    cmsUInt32Number size = 0;
    cmsSaveProfileToMem(profile, nullptr, &size);
    std::vector<unsigned char> blob(size);
    cmsSaveProfileToMem(profile, blob.data(), &size);
    png_set_iCCP(png, info, "sRGB", PNG_COMPRESSION_TYPE_BASE, blob.data(), size);
    cmsCloseProfile(profile);
  }
  png_byte cicp_data[]{12, static_cast<png_byte>(f.transfer), 0,
                       static_cast<png_byte>(f.narrow ? 0 : 1)};
  png_unknown_chunk cicp{};
  if (f.transfer) {
    std::memcpy(cicp.name, "cICP", 4);
    cicp.data = cicp_data;
    cicp.size = 4;
    cicp.location = PNG_HAVE_IHDR;
    png_set_keep_unknown_chunks(png, PNG_HANDLE_CHUNK_ALWAYS, cicp.name, 1);
    png_set_unknown_chunks(png, info, &cicp, 1);
  }
  png_write_info(png, info);
  std::vector<png_bytep> rows(f.height);
  for (unsigned y = 0; y < f.height; ++y)
    rows[y] = const_cast<png_bytep>(f.pixels.data() + y * f.width *
        (f.palette ? 1 : (f.gray ? 1 : 3) + (f.alpha ? 1 : 0)) * (f.bits / 8));
  png_write_image(png, rows.data());
  png_write_end(png, info);
  png_destroy_write_struct(&png, &info);
  return bytes;
}
hyperdr::DecodedImage decode(const Fixture& f, unsigned preview = 0,
                            hyperdr::ColorGamut fallback = hyperdr::ColorGamut::kSrgb) {
  const auto path = std::filesystem::temp_directory_path() / "hyperdr-png-decode-test.png";
  hyperdr::write_binary_file_atomic(path, encode(f), true);
  hyperdr::RawDecodeOptions options;
  options.preview_max_edge = preview;
  options.default_gamut = fallback;
  try {
    auto result = hyperdr::decode_image(path, options);
    std::filesystem::remove(path);
    return result;
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}
void check_gamma() {
  Fixture f;
  f.gamma = 1;
  const auto result = decode(f);
  near(result.linear_p3.pixels[0], 128.0F / 255, "linear gAMA was ignored");
  f.bits = 16;
  f.pixels = {0x12, 0x34, 0x12, 0x34, 0x12, 0x34};
  const auto wide = decode(f);
  near(wide.linear_p3.pixels[0], 4660.0F / 65535, "16-bit PNG byte order or precision changed");
  f.gray = f.icc = true;
  f.gamma = 0;
  f.pixels = {0x12, 0x34};
  const auto gray = decode(f);
  for (float pixel : gray.linear_p3.pixels)
    near(pixel, 4660.0F / 65535, "gray ICC did not decode to neutral linear P3");
}
void check_srgb() {
  Fixture f;
  f.srgb = true;
  f.pixels = {255, 0, 0};
  const auto result = decode(f, 0, hyperdr::ColorGamut::kDisplayP3);
  require(result.source_color.source == "png-srgb" &&
              result.source_color.name == "sRGB",
          "PNG sRGB marker was reported as an assumed input space");
  const auto expected = hyperdr::rec709_to_linear_p3(1, 0, 0);
  for (unsigned c = 0; c < 3; ++c)
    near(result.linear_p3.pixels[c], expected[c], "explicit sRGB lost to default gamut");
}
void check_chrm() {
  Fixture f;
  f.gamma = 1;
  f.p3_chrm = true;
  f.pixels = {255, 0, 0};
  const auto result = decode(f);
  require(result.source_color.source == "png-chrm-gamma",
          "PNG cHRM/gAMA source was not reported");
  for (unsigned c = 0; c < 3; ++c)
    near(result.linear_p3.pixels[c], c == 0 ? 1.0F : 0.0F, "cHRM primaries were ignored");
}
void check_hdr_priority() {
  for (const int transfer : {16, 18}) {
    Fixture f;
    f.transfer = transfer;
    f.icc = true;
    const auto result = decode(f);
    const auto code = 128.0F / 255;
    const auto expected = transfer == 16 ? hyperdr::pq_eotf(code)
        : hyperdr::hlg_decode({code, code, code})[0];
    near(result.linear_p3.pixels[0], expected, "ICC overrode cICP transfer");
    near(result.hdr_headroom, (transfer == 16 ? 10000.0F : 1000.0F) /
         hyperdr::kReferenceWhiteNits, "cICP HDR headroom was lost");
    require(result.domain == hyperdr::InputDomain::kDisplayReferredHdr, "HDR domain was lost");
  }
}
void check_narrow_range() {
  // Independent double-precision reference values for (code - 16) / 219,
  // followed by the specified transfer and (for HLG) the luminance OOTF.
  const std::array<int, 5> transfers{8, 13, 1, 16, 18};
  const std::array<std::array<float, 5>, 5> expected{{
      {-.07305936073F, 0, .5114155251F, 1, 1.091324201F},
      {-.006338424005F, 0, .2247597051F, 1, 1.220483757F},
      {-.0162354135F, 0, .2707113075F, 1, 1.194095459F},
      {-.000721590777F, 0, .5092466833F, 49.26108374F, 119.9603413F},
      {-.002470475431F, 0, .2639353974F, 4.926108518F, 8.988200909F}}};
  for (int bits : {8, 16}) {
    for (unsigned t = 0; t < transfers.size(); ++t) {
      Fixture f;
      f.bits = bits;
      f.narrow = true;
      f.icc = true;  // The lower-priority profile must not consume video codes.
      f.transfer = transfers[t];
      f.width = 5;
      f.pixels.clear();
      for (unsigned code : {0, 16, 128, 235, 255})
        for (unsigned c = 0; c < 3; ++c) {
          f.pixels.push_back(static_cast<unsigned char>(code));
          if (bits == 16) f.pixels.push_back(0);  // 8-bit reference codes * 256.
        }
      const auto result = decode(f);
      for (unsigned x = 0; x < 5; ++x)
        for (unsigned c = 0; c < 3; ++c) {
          const float scale = std::max(1.0F, std::abs(expected[t][x]));
          near(result.linear_p3.at(x, 0, c) / scale, expected[t][x] / scale,
               "narrow PNG lost black/white levels or extended-range values");
        }
      const auto preview = decode(f, 2);
      double mean = 0;
      for (float value : preview.linear_p3.pixels) mean += value;
      float reference = 0;
      for (float value : expected[t]) reference += value / 5;
      const float scale = std::max(1.0F, reference);
      near(static_cast<float>(mean / preview.linear_p3.pixels.size()) / scale,
           reference / scale, "narrow PNG preview clipped before linear averaging");
    }
  }
  Fixture mixed;
  mixed.transfer = 18;
  mixed.narrow = true;
  mixed.pixels = {0, 16, 255};
  const auto result = decode(mixed);
  const std::array<float, 3> expected_mixed{-.00583219524F, 0, 5.410560376F};
  for (unsigned c = 0; c < 3; ++c)
    near(result.linear_p3.pixels[c], expected_mixed[c],
         "extended HLG must use signed scene luminance, not independent channel gamma");
}
void check_preview() {
  for (int bits : {8, 16}) {
    for (bool icc : {false, true}) {
      Fixture f;
      f.bits = bits;
      f.icc = icc;
      f.width = 8;
      f.height = 4;
      f.pixels.resize(f.width * f.height * 3 * (bits / 8));
      for (unsigned y = 0; y < f.height; ++y)
        for (unsigned x = 0; x < f.width; ++x)
          for (int c = 0; c < 3 * (bits / 8); ++c)
            f.pixels[(y * f.width + x) * 3 * (bits / 8) + c] = x % 2 ? 255 : 0;
      auto result = decode(f, 2);
      require(result.linear_p3.width == 2 && result.linear_p3.height == 1, "unexpected PNG preview size");
      for (float pixel : result.linear_p3.pixels)
        near(pixel, .5F, "PNG preview did not average linear light");
      require(!result.decode.resolution_reduced, "preview marked as degraded export");
      require(result.decode.sensor_width == 8 && result.decode.target_height == 4 &&
                  result.decode.decoded_width == 2 && result.decode.decoded_height == 1,
              "PNG source and delivered dimensions were lost");
      f.interlaced = true;
      result = decode(f, 2);
      for (float pixel : result.linear_p3.pixels)
        near(pixel, .5F, "interlaced preview changed linear light");
    }
  }
  // Uniform footprints: a short final column has its source-area weight.
  Fixture odd;
  odd.gamma = 1;
  odd.width = 5;
  odd.height = 3;
  odd.pixels.assign(45, 0);
  for (unsigned y = 0; y < 3; ++y)
    for (unsigned c = 0; c < 3; ++c) odd.pixels[(y * 5 + 4) * 3 + c] = 255;
  const auto result = decode(odd, 2);
  double mean = 0;
  for (float pixel : result.linear_p3.pixels) mean += pixel;
  near(static_cast<float>(mean / result.linear_p3.pixels.size()), .2F, "odd tail changed area weight");
  odd.width = 9;
  odd.pixels.assign(9 * 3 * 3, 0);
  for (unsigned y = 0; y < 3; ++y)
    for (unsigned c = 0; c < 3; ++c) odd.pixels[(y * 9 + 3) * 3 + c] = 255;
  const auto ordinary = decode(odd, 3);
  odd.interlaced = true;
  const auto interlaced = decode(odd, 3);
  for (std::size_t i = 0; i < ordinary.linear_p3.pixels.size(); ++i)
    near(interlaced.linear_p3.pixels[i], ordinary.linear_p3.pixels[i],
         "Adam7 changed the preview reduction kernel");
}
void check_decode_errors() {
  const auto path = std::filesystem::temp_directory_path() / "hyperdr-png-truncated-test.png";
  auto bytes = encode(Fixture{});
  bytes.resize(bytes.size() - 16);
  hyperdr::write_binary_file_atomic(path, bytes, true);
  bool rejected = false;
  try { (void)hyperdr::decode_image(path); }
  catch (const std::runtime_error&) { rejected = true; }
  std::filesystem::remove(path);
  require(rejected, "truncated PNG must fail through the C++ error boundary");
  // A subsequent valid decode must still work after a libpng longjmp.
  (void)decode(Fixture{});
}
void check_block_boundaries() {
  Fixture f;
  f.icc = true;
  f.width = 129;
  f.height = 131;
  f.pixels.resize(f.width * f.height * 3);
  unsigned white = 0;
  for (unsigned y = 0; y < f.height; ++y)
    for (unsigned x = 0; x < f.width; ++x) {
      const bool bright = (x + y) % 11 == 0;
      white += bright;
      for (unsigned c = 0; c < 3; ++c) f.pixels[(y * f.width + x) * 3 + c] = bright ? 255 : 0;
    }
  const auto result = decode(f, 7);
  double sum = 0;
  for (float value : result.linear_p3.pixels) sum += value;
  near(static_cast<float>(sum / result.linear_p3.pixels.size()),
       static_cast<float>(white) / (f.width * f.height), "64-row block boundary changed image energy");
  f.interlaced = true;
  const auto interlaced = decode(f, 7);
  for (std::size_t i = 0; i < result.linear_p3.pixels.size(); ++i)
    near(interlaced.linear_p3.pixels[i], result.linear_p3.pixels[i], "Adam7 block boundary mismatch");
}

void check_alpha() {
  for (int bits : {8, 16}) for (bool interlaced : {false, true}) {
    Fixture f;
    f.bits = bits; f.alpha = true; f.srgb = true; f.interlaced = interlaced;
    f.width = 2; f.height = 2;
    f.pixels.clear();
    const unsigned maximum = (1U << bits) - 1, half = maximum / 2;
    for (unsigned i = 0; i < 4; ++i) {
      for (unsigned value : {maximum, maximum, maximum, i == 0 ? 0U : i == 1 ? half : maximum}) {
        if (bits == 16) f.pixels.push_back(static_cast<unsigned char>(value >> 8));
        f.pixels.push_back(static_cast<unsigned char>(value));
      }
    }
    const auto full = decode(f);
    const auto reduced = decode(f, 1);
    for (unsigned c = 0; c < 3; ++c) {
      near(full.linear_p3.at(0, 0, c), 0, "transparent PNG hidden colour became visible");
      near(full.linear_p3.at(1, 0, c), static_cast<float>(half) / maximum,
           "PNG alpha was composited in encoded light");
      near(reduced.linear_p3.pixels[c], (2 + static_cast<float>(half) / maximum) / 4,
           "PNG reduction happened before linear alpha composition");
    }
  }
  Fixture gray;
  gray.gray = gray.icc = gray.alpha = true;
  gray.pixels = {128, 64};
  for (float value : decode(gray).linear_p3.pixels)
    near(value, (128.0F / 255) * (64.0F / 255), "gray ICC alpha was lost");
  Fixture palette;
  palette.width = 2; palette.palette = palette.srgb = true;
  palette.pixels = {0, 1};
  const auto result = decode(palette, 1);
  const auto blue = hyperdr::rec709_to_linear_p3(0, 0, 0.5F);
  for (unsigned c = 0; c < 3; ++c)
    near(result.linear_p3.pixels[c], blue[c], "palette tRNS leaked hidden RGB into reduction");
}
void check_content_peak() {
  for (int transfer : {16, 18}) {
    Fixture f;
    f.transfer = transfer;
    require(!decode(f).content_peak_nits, "missing PNG cLLI invented a content peak");
    f.content_peak = 0;
    require(!decode(f).content_peak_nits, "zero PNG cLLI was not unknown");
    f.content_peak = 2031250;
    const auto result = decode(f);
    require(result.content_peak_nits.has_value(), "PNG cLLI content peak was lost");
    near(*result.content_peak_nits, 203.125F, "PNG cLLI units are not 0.0001 nit");
    require(result.describe_input().content_peak_nits == result.content_peak_nits,
            "HDR input description lost content peak");
    near(result.hdr_headroom, (transfer == 16 ? 10000.0F : 1000.0F) / hyperdr::kReferenceWhiteNits,
         "content peak changed transfer headroom");
    f.transfer = 13;
    require(!decode(f).content_peak_nits, "SDR cICP consumed HDR content peak");
    f.transfer = 0;
    f.icc = true;
    require(!decode(f).content_peak_nits, "ICC consumed HDR content peak");
  }
}
}  // namespace

int main() {
  int failures = 0;
  for (auto test : {check_gamma, check_srgb, check_chrm, check_hdr_priority, check_narrow_range, check_preview,
                    check_decode_errors, check_block_boundaries, check_alpha, check_content_peak}) {
    try { test(); }
    catch (const std::exception& error) { std::cerr << error.what() << '\n'; ++failures; }
  }
  if (!failures) std::cout << "PNG color and linear preview tests passed\n";
  return failures ? 1 : 0;
}
