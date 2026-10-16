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

#include "hyperdr/foundation/version.hpp"
#include <stdexcept>
#include <string>

namespace hyperdr {

std::string codec_runtime_fingerprint() {
  return std::string("build=") + HYPERDR_BUILD_ID + "|version=" + kVersion;
}

void fail_without_codecs(const char* capability) {
  throw std::runtime_error(std::string(capability) +
                           " requires a codec-enabled build "
                           "(configure with -DHYPERDR_WITH_CODECS=ON)");
}

#if !HYPERDR_WITH_CODECS

RawLensMetadata probe_raw_lens_metadata(const std::filesystem::path&) {
  fail_without_codecs("RAW metadata probing");
}

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
                                               const PhotoMetadata&, int, int, HevcPreset) {
  fail_without_codecs("Adaptive HDR HEIC encoding");
}

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const GainMapResult&,
                                               const PhotoMetadata&, int) {
  fail_without_codecs("Ultra HDR JPEG encoding");
}

std::vector<std::uint8_t> encode_hdr_heic(const PhotoRenditions&,
                                          const PhotoMetadata&, int, HdrEncoding, HevcPreset) {
  fail_without_codecs("BT.2100 HEIC encoding");
}

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const PhotoRenditions&,
    const PhotoMetadata&, int) {
  fail_without_codecs("Ultra HDR rendition encoding");
}
std::vector<std::uint8_t> encode_ultrahdr_jpeg(const FloatImage&,
    const std::vector<std::uint8_t>&, ColorGamut, float, int) {
  fail_without_codecs("Ultra HDR JPEG reuse");
}
UltraHdrInfo probe_ultrahdr_jpeg(const std::vector<std::uint8_t>&) {
  fail_without_codecs("Ultra HDR metadata inspection");
}

std::vector<std::uint8_t> encode_avif(const PhotoRenditions&, const PhotoMetadata&,
                                      int, HdrEncoding) {
  fail_without_codecs("AVIF encoding");
}

std::vector<std::uint8_t> encode_sdr_jpeg(const FloatImage&, const PhotoMetadata&, int, ColorGamut) {
  fail_without_codecs("SDR JPEG encoding");
}
void verify_sdr_jpeg(const std::vector<std::uint8_t>&) { fail_without_codecs("SDR JPEG verification"); }
std::vector<std::uint8_t> encode_sdr_tiff(const FloatImage&, const PhotoMetadata&, ColorGamut) {
  fail_without_codecs("SDR TIFF encoding");
}
void verify_sdr_tiff(const std::vector<std::uint8_t>&) { fail_without_codecs("SDR TIFF verification"); }

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
