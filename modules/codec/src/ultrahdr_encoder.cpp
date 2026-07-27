#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <jpeglib.h>
#include <ultrahdr_api.h>

#include <algorithm>
#include <cmath>
#include <csetjmp>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
namespace {

struct JpegError {
  jpeg_error_mgr base{};
  std::jmp_buf jump{};
  char message[JMSG_LENGTH_MAX]{};
};

void jpeg_fail(j_common_ptr info) {
  auto* error = reinterpret_cast<JpegError*>(info->err);
  (*info->err->format_message)(info, error->message);
  std::longjmp(error->jump, 1);
}

std::vector<std::uint8_t> compress_jpeg(const std::uint8_t* pixels, std::uint32_t width,
                                        std::uint32_t height, int components,
                                        J_COLOR_SPACE color_space, int quality,
                                        const std::vector<std::uint8_t>* exif_tiff = nullptr) {
  if (!pixels || width == 0 || height == 0) {
    throw std::invalid_argument("cannot encode an empty JPEG image");
  }

  jpeg_compress_struct info{};
  JpegError error{};
  unsigned char* output = nullptr;
  unsigned long output_size = 0;
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_compress(&info);
    std::free(output);
    throw std::runtime_error(std::string("JPEG encode: ") + error.message);
  }

  jpeg_create_compress(&info);
  jpeg_mem_dest(&info, &output, &output_size);
  info.image_width = width;
  info.image_height = height;
  info.input_components = components;
  info.in_color_space = color_space;
  jpeg_set_defaults(&info);
  jpeg_set_quality(&info, std::clamp(quality, 0, 100), TRUE);
  info.optimize_coding = TRUE;
  jpeg_start_compress(&info, TRUE);

  if (exif_tiff && !exif_tiff->empty()) {
    std::vector<std::uint8_t> marker{'E', 'x', 'i', 'f', 0, 0};
    marker.insert(marker.end(), exif_tiff->begin(), exif_tiff->end());
    if (marker.size() > 65533) throw std::runtime_error("Exif data is too large for JPEG APP1");
    jpeg_write_marker(&info, JPEG_APP0 + 1, marker.data(),
                      static_cast<unsigned int>(marker.size()));
  }

  const std::size_t stride = static_cast<std::size_t>(width) * components;
  while (info.next_scanline < info.image_height) {
    auto* row = const_cast<JSAMPLE*>(
        pixels + static_cast<std::size_t>(info.next_scanline) * stride);
    jpeg_write_scanlines(&info, &row, 1);
  }
  jpeg_finish_compress(&info);
  std::vector<std::uint8_t> result(output, output + output_size);
  jpeg_destroy_compress(&info);
  std::free(output);
  return result;
}

std::vector<std::uint8_t> make_base_jpeg(const FloatImage& image,
                                         const PhotoMetadata& metadata, int quality) {
  if (image.channels != 3) throw std::invalid_argument("Ultra HDR base must be RGB");
  std::vector<std::uint8_t> rgb(static_cast<std::size_t>(image.width) * image.height * 3);
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto base = (static_cast<std::size_t>(y) * image.width + x) * 3;
      for (unsigned c = 0; c < 3; ++c) {
        rgb[base + c] = static_cast<std::uint8_t>(quantize_dithered(
            srgb_oetf(image.at(x, y, c)), 255, x, y, c));
      }
    }
  }
  const auto exif = make_minimal_exif(metadata);
  return compress_jpeg(rgb.data(), image.width, image.height, 3, JCS_RGB, quality, &exif);
}

std::vector<std::uint8_t> make_gain_jpeg(const FloatImage& image, int quality) {
  if (image.channels != 1) throw std::invalid_argument("Ultra HDR gain map must be monochrome");
  std::vector<std::uint8_t> gray(static_cast<std::size_t>(image.width) * image.height);
  for (std::size_t i = 0; i < gray.size(); ++i) {
    gray[i] = static_cast<std::uint8_t>(
        std::lround(std::clamp(image.pixels[i], 0.0F, 1.0F) * 255.0F));
  }
  return compress_jpeg(gray.data(), image.width, image.height, 1, JCS_GRAYSCALE, quality);
}

float value(const Rational& rational) {
  if (rational.denominator == 0) throw std::invalid_argument("zero gain-map denominator");
  return static_cast<float>(rational.numerator) /
         static_cast<float>(rational.denominator);
}

float boost_from_stops(float stops) {
  return std::exp2(std::clamp(stops, -126.0F, 126.0F));
}

void check_uhdr(uhdr_error_info_t status, const char* operation) {
  if (status.error_code == UHDR_CODEC_OK) return;
  const std::string detail = status.has_detail ? status.detail : "unknown libultrahdr error";
  throw std::runtime_error(std::string(operation) + ": " + detail);
}

struct EncoderDeleter {
  void operator()(uhdr_codec_private_t* encoder) const {
    if (encoder) uhdr_release_encoder(encoder);
  }
};

struct DecoderDeleter {
  void operator()(uhdr_codec_private_t* decoder) const {
    if (decoder) uhdr_release_decoder(decoder);
  }
};

bool contains_text(const std::vector<std::uint8_t>& bytes, const char* text) {
  const auto length = std::strlen(text);
  return std::search(bytes.begin(), bytes.end(), text, text + length) != bytes.end();
}

}  // namespace

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const GainMapResult& images,
                                               const PhotoMetadata& metadata, int quality) {
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  auto base_bytes = make_base_jpeg(images.base_linear, metadata, quality);
  // The format guidance recommends 85-90 for the recovery map. Keep HDR
  // reconstruction stable even when the caller deliberately lowers base quality.
  auto gain_bytes = make_gain_jpeg(images.gain_map, std::max(85, quality));

  uhdr_compressed_image_t base{};
  base.data = base_bytes.data();
  base.data_sz = base.capacity = base_bytes.size();
  base.cg = UHDR_CG_DISPLAY_P3;
  base.ct = UHDR_CT_SRGB;
  base.range = UHDR_CR_FULL_RANGE;

  uhdr_compressed_image_t gain{};
  gain.data = gain_bytes.data();
  gain.data_sz = gain.capacity = gain_bytes.size();
  gain.cg = UHDR_CG_UNSPECIFIED;
  gain.ct = UHDR_CT_UNSPECIFIED;
  gain.range = UHDR_CR_UNSPECIFIED;

  uhdr_gainmap_metadata_t gain_metadata{};
  const float min_boost = boost_from_stops(value(images.metadata.gain_min));
  const float max_boost = boost_from_stops(value(images.metadata.gain_max));
  const float gamma = value(images.metadata.gamma);
  const float sdr_offset = value(images.metadata.base_offset);
  const float hdr_offset = value(images.metadata.alternate_offset);
  for (unsigned c = 0; c < 3; ++c) {
    gain_metadata.min_content_boost[c] = min_boost;
    gain_metadata.max_content_boost[c] = max_boost;
    gain_metadata.gamma[c] = gamma;
    gain_metadata.offset_sdr[c] = sdr_offset;
    gain_metadata.offset_hdr[c] = hdr_offset;
  }
  gain_metadata.hdr_capacity_min = boost_from_stops(value(images.metadata.base_headroom));
  gain_metadata.hdr_capacity_max = boost_from_stops(value(images.metadata.alternate_headroom));
  if (gain_metadata.hdr_capacity_max <= gain_metadata.hdr_capacity_min) {
    gain_metadata.hdr_capacity_max = gain_metadata.hdr_capacity_min * 1.0001F;
  }
  gain_metadata.use_base_cg = images.metadata.use_base_color_space ? 1 : 0;

  std::unique_ptr<uhdr_codec_private_t, EncoderDeleter> encoder(uhdr_create_encoder());
  if (!encoder) throw std::runtime_error("cannot allocate libultrahdr encoder");
  check_uhdr(uhdr_enc_set_compressed_image(encoder.get(), &base, UHDR_BASE_IMG),
             "set Ultra HDR base image");
  check_uhdr(uhdr_enc_set_gainmap_image(encoder.get(), &gain, &gain_metadata),
             "set Ultra HDR gain map");
  check_uhdr(uhdr_enc_set_output_format(encoder.get(), UHDR_CODEC_JPG),
             "set Ultra HDR output format");
  check_uhdr(uhdr_encode(encoder.get()), "encode Ultra HDR JPEG/R");
  const auto* output = uhdr_get_encoded_stream(encoder.get());
  if (!output || !output->data || output->data_sz == 0) {
    throw std::runtime_error("libultrahdr returned an empty JPEG/R stream");
  }
  const auto* begin = static_cast<const std::uint8_t*>(output->data);
  return {begin, begin + output->data_sz};
}

void verify_ultrahdr_jpeg(const std::vector<std::uint8_t>& bytes) {
  if (bytes.size() < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8 ||
      bytes[bytes.size() - 2] != 0xFF || bytes.back() != 0xD9) {
    throw std::runtime_error("Ultra HDR output is not a complete JPEG stream");
  }
  if (!contains_text(bytes, "hdrgm:Version") ||
      !contains_text(bytes, "http://ns.adobe.com/hdr-gain-map/1.0/") ||
      !contains_text(bytes, "urn:iso:std:iso:ts:21496:-1")) {
    throw std::runtime_error("Ultra HDR JPEG lacks required XMP/ISO gain-map metadata");
  }
  if (bytes.size() > static_cast<std::size_t>(std::numeric_limits<int>::max())) {
    throw std::runtime_error("Ultra HDR JPEG is too large for the reference decoder");
  }
  if (!is_uhdr_image(const_cast<std::uint8_t*>(bytes.data()), static_cast<int>(bytes.size()))) {
    throw std::runtime_error("libultrahdr did not recognize the encoded JPEG/R stream");
  }

  uhdr_compressed_image_t input{};
  input.data = const_cast<std::uint8_t*>(bytes.data());
  input.data_sz = input.capacity = bytes.size();
  input.cg = UHDR_CG_UNSPECIFIED;
  input.ct = UHDR_CT_UNSPECIFIED;
  input.range = UHDR_CR_UNSPECIFIED;
  std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> decoder(uhdr_create_decoder());
  if (!decoder) throw std::runtime_error("cannot allocate libultrahdr verifier");
  check_uhdr(uhdr_dec_set_image(decoder.get(), &input), "open Ultra HDR JPEG");
  check_uhdr(uhdr_dec_set_out_img_format(decoder.get(), UHDR_IMG_FMT_64bppRGBAHalfFloat),
             "set Ultra HDR verification format");
  check_uhdr(uhdr_dec_set_out_color_transfer(decoder.get(), UHDR_CT_LINEAR),
             "set Ultra HDR verification transfer");
  check_uhdr(uhdr_dec_probe(decoder.get()), "probe Ultra HDR JPEG");
  if (uhdr_dec_get_image_width(decoder.get()) <= 0 ||
      uhdr_dec_get_image_height(decoder.get()) <= 0 ||
      uhdr_dec_get_gainmap_width(decoder.get()) <= 0 ||
      uhdr_dec_get_gainmap_height(decoder.get()) <= 0 ||
      !uhdr_dec_get_gainmap_metadata(decoder.get()) || !uhdr_dec_get_icc(decoder.get())) {
    throw std::runtime_error("Ultra HDR JPEG probe returned incomplete base/gain-map data");
  }
  check_uhdr(uhdr_decode(decoder.get()), "decode reconstructed Ultra HDR rendition");
  if (!uhdr_get_decoded_image(decoder.get())) {
    throw std::runtime_error("Ultra HDR verifier returned no reconstructed image");
  }
}

void verify_ultrahdr_jpeg(const std::filesystem::path& input) {
  verify_ultrahdr_jpeg(read_binary_file(input));
}

}  // namespace hyperdr
