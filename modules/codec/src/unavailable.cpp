// Every codec entry point, defined for the build that has no codecs.
//
// The alternative was `#if HYPERDR_WITH_CODECS` inside the conversion runner and
// the CLI, which made the core build a structurally different program from the
// shipping one: branches existed in one and not the other, and neither
// configuration ever compiled both halves. Here the declarations, the call
// sites, and the error messages are shared, and only these definitions differ.

#include "hyperdr/codec/raw_compat.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoder_capabilities.hpp"
#include "hyperdr/codec/gain_map_jpeg.hpp"
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
const char* raw_converter_id() noexcept { return "libraw-unavailable/dng-3"; }
std::string raw_convert_dng(const std::filesystem::path&, const std::filesystem::path&) {
  fail_without_codecs("LibRaw DNG compatibility");
}
std::string raw_extract_preview(const std::filesystem::path&, const std::filesystem::path&) {
  fail_without_codecs("LibRaw preview extraction");
}

void write_sdr_jpeg_rows(const EncodingRows&,const PhotoMetadata&,int,ColorGamut,const std::filesystem::path&){fail_without_codecs("streaming JPEG");}
void write_sdr_tiff_rows(const EncodingRows&,const PhotoMetadata&,ColorGamut,const std::filesystem::path&){fail_without_codecs("streaming TIFF");}
void write_lossless_rows(const EncodingRows&,const LinearHdrGain*,const PhotoMetadata&,OutputEncoding,ColorGamut,const std::filesystem::path&){fail_without_codecs("lossless TIFF/DNG");}
void write_gain_map_jpeg_rows(const EncodingRows&,const EncodingRows&,const GainMapMetadata&,const PhotoMetadata&,int,bool,const std::filesystem::path&){fail_without_codecs("streaming ISO JPEG");}
void write_adaptive_heic(const GainMapResult&,const PhotoMetadata&,int,int,const std::filesystem::path&){fail_without_codecs("HEIC");}
void write_hdr_heic(const PhotoRenditions&,const PhotoMetadata&,int,HdrEncoding,const std::filesystem::path&){fail_without_codecs("HEIC");}
void write_heic_rows(const EncodingRows&,const EncodingRows&,const GainMapMetadata&,float,const PhotoMetadata&,OutputEncoding,int,int,bool,const std::filesystem::path&){fail_without_codecs("streaming HEIC");}

EncoderCapabilities encoder_capabilities(const std::filesystem::path&) {
  return {false, false, "hevc_unavailable"};
}

namespace codec {
GainMapRead read_gain_map_jpeg_imageio(const std::vector<std::uint8_t>&) { fail_without_codecs("gain-map JPEG input"); }
namespace testing { void set_imageio_gain_map_hook(void (*)(bool) noexcept) {} }
}

RawHeader probe_apple_raw(const std::filesystem::path&) { fail_without_codecs("RAW probing"); }
float raw_preview_scale(const std::filesystem::path&, std::uint32_t) { return 1; }
std::string raw_os_build(){ return {}; }
float raw_preview_scale(std::uint32_t edge,std::uint32_t source){
  if(!edge||!source)return 1;for(float s:{.125F,.25F,.5F,1.F})if(source*s>=edge)return s;return 1;
}
void release_apple_raw_cache(const std::filesystem::path&) {}

RawLensMetadata probe_raw_lens_metadata(const std::filesystem::path&) {
  fail_without_codecs("RAW metadata probing");
}

DecodedImage decode_image(const std::filesystem::path&, const RawDecodeOptions&) {
  fail_without_codecs("image decoding");
}





bool is_ultrahdr_jpeg_file(const std::filesystem::path&) { return false; }

DecodedImage decode_ultrahdr(const std::filesystem::path&) {
  fail_without_codecs("Ultra HDR JPEG decoding");
}

bool is_avif_file(const std::filesystem::path&) { return false; }

DecodedImage decode_avif(const std::filesystem::path&) {
  fail_without_codecs("AVIF decoding");
}


std::vector<std::uint8_t> encode_adaptive_heic(const GainMapResult&,
                                               const PhotoMetadata&, int, int) {
  fail_without_codecs("Adaptive HDR HEIC encoding");
}

std::vector<std::uint8_t> encode_gain_map_jpeg(const GainMapResult&,
                                               const PhotoMetadata&, int) {
  fail_without_codecs("ISO gain-map JPEG encoding");
}

std::vector<std::uint8_t> encode_gain_map_jpeg(GainMapResult&&,
                                               const PhotoMetadata&, int) {
  fail_without_codecs("ISO gain-map JPEG encoding");
}

std::vector<std::uint8_t> encode_hdr_heic(const PhotoRenditions&,
                                          const PhotoMetadata&, int, HdrEncoding) {
  fail_without_codecs("BT.2100 HEIC encoding");
}

std::vector<std::uint8_t> encode_avif(const PhotoRenditions&, const PhotoMetadata&,
                                      int, HdrEncoding, const AvifGridLayout*) {
  fail_without_codecs("AVIF encoding");
}

namespace testing {
void set_jpeg_progress_observer(void (*)(bool)) {}
}  // namespace testing

std::vector<std::uint8_t> encode_sdr_jpeg(const FloatImage&, const PhotoMetadata&, int, ColorGamut) {
  fail_without_codecs("SDR JPEG encoding");
}
void verify_sdr_jpeg(std::span<const std::uint8_t>) { fail_without_codecs("SDR JPEG verification"); }
std::vector<std::uint8_t> encode_sdr_tiff(const FloatImage&, const PhotoMetadata&, ColorGamut) {
  fail_without_codecs("SDR TIFF encoding");
}
void verify_sdr_tiff(std::span<const std::uint8_t>) { fail_without_codecs("SDR TIFF verification"); }

void verify_encoded_output(std::span<const std::uint8_t>, HdrEncoding) {
  fail_without_codecs("output verification");
}
void verify_heic_decodable(std::span<const std::uint8_t>) {
  fail_without_codecs("HEIC decode verification");
}

void verify_heic_decodable(std::span<const std::uint8_t>, HdrEncoding) {
  fail_without_codecs("HEIC decode verification");
}

void verify_heic_decodable(const std::filesystem::path&) {
  fail_without_codecs("HEIC decode verification");
}

void verify_gain_map_jpeg(std::span<const std::uint8_t>) {
  fail_without_codecs("ISO gain-map JPEG verification");
}

void verify_gain_map_jpeg(const std::filesystem::path&) {
  fail_without_codecs("ISO gain-map JPEG verification");
}

void verify_avif_decodable(std::span<const std::uint8_t>) {
  fail_without_codecs("AVIF decode verification");
}
VerificationResult verify_avif_pixels(std::span<const std::uint8_t>, const AvifCellDigests*) {
  fail_without_codecs("AVIF decode verification");
}
VerificationResult verify_avif_file(const std::filesystem::path&, const AvifCellDigests&) {
  fail_without_codecs("AVIF decode verification");
}
AvifCellDigests write_avif_rows(const EncodingRows&, const EncodingRows&, const GainMapMetadata&,
    float, const PhotoMetadata&, HdrEncoding, int, const std::filesystem::path&, bool) {
  fail_without_codecs("AVIF row encoding");
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
#if !HYPERDR_WITH_CODECS
namespace hyperdr {
VerificationResult verify_encoded_file(const std::filesystem::path&,HdrEncoding,std::optional<VerificationFrame>) {
  throw std::runtime_error("output verification needs codecs");
}
}
#endif
