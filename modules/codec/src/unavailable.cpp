// Every codec entry point, defined for the build that has no codecs.
//
// The alternative was `#if HYPERDR_WITH_CODECS` inside the conversion runner and
// the CLI, which made the core build a structurally different program from the
// shipping one: branches existed in one and not the other, and neither
// configuration ever compiled both halves. Here the declarations, the call
// sites, and the error messages are shared, and only these definitions differ.

#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <system_error>
#include <vector>

#include <windows.h>

namespace hyperdr {

namespace {

std::filesystem::path current_executable_path() {
  std::array<wchar_t, 32768> buffer{};
  const DWORD length = GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0 || length >= buffer.size()) {
    throw std::runtime_error("cannot identify the running executable");
  }
  return std::filesystem::path(std::wstring(buffer.data(), length));
}

std::string lowercase_extension(const std::filesystem::path& path) {
  std::string extension = path.extension().string();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](const unsigned char value) {
                   return static_cast<char>(std::tolower(value));
                 });
  return extension;
}

}  // namespace

std::string codec_runtime_fingerprint() {
  const auto executable = current_executable_path();
  std::string out = "binary=" + sha256_file_hex(executable);
#if HYPERDR_WITH_CODECS
  out += "|codecs=enabled";
  std::vector<std::filesystem::path> libraries;
  std::error_code error;
  for (std::filesystem::directory_iterator it(executable.parent_path(), error),
       end;
       !error && it != end; it.increment(error)) {
    std::error_code file_error;
    if (!it->is_regular_file(file_error) || file_error ||
        lowercase_extension(it->path()) != ".dll") {
      continue;
    }
    libraries.push_back(it->path());
  }
  if (error) throw std::runtime_error("cannot enumerate codec runtimes");
  std::sort(libraries.begin(), libraries.end(), [](const auto& left, const auto& right) {
    return path_utf8(left.filename()) < path_utf8(right.filename());
  });
  for (const auto& library : libraries) {
    out += "|dll:" + path_utf8(library.filename()) + "=" +
           sha256_file_hex(library);
  }
#else
  out += "|codecs=disabled";
#endif
  return out;
}

void fail_without_codecs(const char* capability) {
  throw std::runtime_error(std::string(capability) +
                           " requires a codec-enabled build "
                           "(configure with -DHYPERDR_WITH_CODECS=ON)");
}

#if !HYPERDR_WITH_CODECS

DecodedImage decode_image(const std::filesystem::path&, const RawDecodeOptions&) {
  fail_without_codecs("image decoding");
}

RawMosaic decode_raw_mosaic(const std::filesystem::path&,
                            const RawDecodeOptions&) {
  fail_without_codecs("RAW mosaic decoding");
}

bool is_ultrahdr_jpeg_file(const std::filesystem::path&) { return false; }

DecodedImage decode_ultrahdr(const std::filesystem::path&) {
  fail_without_codecs("Ultra HDR JPEG decoding");
}

bool is_avif_file(const std::filesystem::path&) { return false; }

DecodedImage decode_avif(const std::filesystem::path&) {
  fail_without_codecs("AVIF decoding");
}

PreviewJpeg encode_preview_jpeg(const std::filesystem::path&, std::uint32_t, int,
                                const RawDecodeOptions&, bool) {
  fail_without_codecs("thumbnail generation");
}

std::vector<std::uint8_t> encode_adaptive_heic(const GainMapResult&,
                                               const PhotoMetadata&, int, int) {
  fail_without_codecs("Adaptive HDR HEIC encoding");
}

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const GainMapResult&,
                                               const PhotoMetadata&, int) {
  fail_without_codecs("Ultra HDR JPEG encoding");
}

std::vector<std::uint8_t> encode_hdr_heic(const GainMapResult&,
                                          const PhotoMetadata&, int, HdrEncoding) {
  fail_without_codecs("BT.2100 HEIC encoding");
}

std::vector<std::uint8_t> encode_avif(const GainMapResult&, const PhotoMetadata&,
                                      int, HdrEncoding) {
  fail_without_codecs("AVIF encoding");
}

void verify_heic_decodable(const std::vector<std::uint8_t>&) {
  fail_without_codecs("HEIC decode verification");
}

void verify_heic_decodable(const std::vector<std::uint8_t>&, HdrEncoding) {
  fail_without_codecs("HEIC decode verification");
}

void verify_heic_decodable(const std::filesystem::path&) {
  fail_without_codecs("HEIC decode verification");
}

void verify_ultrahdr_jpeg(const std::vector<std::uint8_t>&) {
  fail_without_codecs("Ultra HDR JPEG verification");
}

void verify_ultrahdr_jpeg(const std::filesystem::path&) {
  fail_without_codecs("Ultra HDR JPEG verification");
}

void verify_avif_decodable(const std::vector<std::uint8_t>&) {
  fail_without_codecs("AVIF decode verification");
}

void reconstruct_heic_to_tiff(const std::filesystem::path&,
                              const std::filesystem::path&) {
  fail_without_codecs("gain-map reconstruction");
}

DisplayCurveResult compare_gain_map_heic_curve(
    const std::filesystem::path&, const std::filesystem::path&,
    const std::vector<float>&) {
  fail_without_codecs("display-curve comparison");
}

#endif  // !HYPERDR_WITH_CODECS

}  // namespace hyperdr
