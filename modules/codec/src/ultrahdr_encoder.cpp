#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "internal/icc_profiles.hpp"

#include <jpeglib.h>
#include <ultrahdr_api.h>
#include <lcms2.h>

#include <algorithm>
#include <bit>
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
                                        const std::vector<std::uint8_t>* exif_tiff = nullptr,
                                        const std::vector<std::uint8_t>* icc = nullptr,
                                        bool full_chroma = false) {
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
  if (full_chroma) {
    for (int component = 0; component < info.num_components; ++component) {
      info.comp_info[component].h_samp_factor = 1;
      info.comp_info[component].v_samp_factor = 1;
    }
  }
  info.optimize_coding = TRUE;
  jpeg_start_compress(&info, TRUE);

  if (icc && !icc->empty()) {
    std::vector<std::uint8_t> marker{'I','C','C','_','P','R','O','F','I','L','E',0,1,1};
    marker.insert(marker.end(), icc->begin(), icc->end());
    jpeg_write_marker(&info, JPEG_APP0 + 2, marker.data(), static_cast<unsigned int>(marker.size()));
  }

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
                                         const PhotoMetadata& metadata, int quality,
                                         bool clamp_srgb, bool full_chroma) {
  if (image.channels != 3) throw std::invalid_argument("Ultra HDR base must be RGB");
  std::vector<std::uint8_t> rgb(static_cast<std::size_t>(image.width) * image.height * 3);
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x) {
      const auto base = (static_cast<std::size_t>(y) * image.width + x) * 3;
      const auto fitted = clamp_srgb
                              ? compress_linear_p3_to_srgb(
                                    image.pixels[base], image.pixels[base + 1],
                                    image.pixels[base + 2])
                              : std::array<float, 3>{image.pixels[base],
                                                     image.pixels[base + 1],
                                                     image.pixels[base + 2]};
      for (unsigned c = 0; c < 3; ++c) {
        rgb[base + c] = static_cast<std::uint8_t>(quantize_dithered(
            srgb_oetf(fitted[c]), 255, x, y, c));
      }
    }
  }
  const auto exif = make_minimal_exif(metadata);
  // Gamut compression retains P3 coordinates even when clamp_srgb is enabled.
  // Both modes therefore store Display P3 primaries with the sRGB transfer.
  const auto icc = codec::display_p3_profile();
  return compress_jpeg(rgb.data(), image.width, image.height, 3, JCS_RGB, quality, &exif,
                       &icc, full_chroma);
}

std::vector<std::uint8_t> make_gain_jpeg(const FloatImage& image, int quality) {
  if (image.channels != 1 && image.channels != 3) {
    throw std::invalid_argument("Ultra HDR gain map must have one or three channels");
  }
  std::vector<std::uint8_t> pixels(image.pixels.size());
  for (std::size_t i = 0; i < pixels.size(); ++i) {
    pixels[i] = static_cast<std::uint8_t>(
        std::lround(std::clamp(image.pixels[i], 0.0F, 1.0F) * 255.0F));
  }
  return compress_jpeg(pixels.data(), image.width, image.height, image.channels,
      image.channels == 1 ? JCS_GRAYSCALE : JCS_RGB, quality, nullptr, nullptr, true);
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

// Nonnegative finite binary32 -> binary16, round to nearest, ties to even.
// Input is checked against the linear HDR range before reaching this helper.
constexpr std::uint16_t linear_half(float input) {
  const auto bits = std::bit_cast<std::uint32_t>(input);
  const int exponent = static_cast<int>((bits >> 23) & 255) - 127;
  if (exponent < -25) return 0;
  if (exponent < -14) {
    const auto mantissa = (bits & 0x7fffffU) | 0x800000U;
    const unsigned shift = static_cast<unsigned>(-exponent - 1);
    return static_cast<std::uint16_t>((mantissa + ((1U << (shift - 1)) - 1) +
        ((mantissa >> shift) & 1U)) >> shift);
  }
  const auto rounded = bits + 0xfffU + ((bits >> 13) & 1U);
  return static_cast<std::uint16_t>((rounded - (112U << 23)) >> 13);
}
static_assert(linear_half(1.0F) == 0x3c00 && linear_half(4.0F) == 0x4400);
static_assert(linear_half(0x1p-24F) == 1 && linear_half(0x1p-25F) == 0);
static_assert(linear_half(1.00048828125F) == 0x3c00);

}  // namespace

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const FloatImage& hdr,
    const std::vector<std::uint8_t>& sdr_jpeg, ColorGamut sdr_gamut,
    float headroom_stops, int gain_quality) {
  hdr.require_consistent("Ultra HDR linear input");
  if (hdr.channels != 3) throw std::invalid_argument("Ultra HDR linear input must be RGB");
  if (gain_quality < 0 || gain_quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  const float peak_nits = 203.0F * std::exp2(headroom_stops);
  if (!std::isfinite(peak_nits) || peak_nits < 203.0F || peak_nits > 10000.01F) {
    throw std::invalid_argument("Ultra HDR display peak must be in [203,10000] nits");
  }
  std::vector<std::uint16_t> rgba(static_cast<std::size_t>(hdr.width) * hdr.height * 4);
  for (std::size_t i = 0; i < hdr.pixels.size() / 3; ++i) {
    for (unsigned c = 0; c < 3; ++c) {
      const float v = hdr.pixels[i * 3 + c];
      if (!std::isfinite(v) || v < 0 || v > 10000.01F / 203.0F) {
        throw std::invalid_argument("Ultra HDR linear pixels must be finite and in [0,10000/203]");
      }
      rgba[i * 4 + c] = linear_half(v == 0 ? 0.0F : v);
    }
    rgba[i * 4 + 3] = 0x3c00;
  }
  uhdr_raw_image_t raw{};
  raw.fmt = UHDR_IMG_FMT_64bppRGBAHalfFloat;
  raw.cg = UHDR_CG_DISPLAY_P3;
  raw.ct = UHDR_CT_LINEAR;
  raw.range = UHDR_CR_FULL_RANGE;
  raw.w = hdr.width;
  raw.h = hdr.height;
  raw.planes[UHDR_PLANE_PACKED] = rgba.data();
  raw.stride[UHDR_PLANE_PACKED] = hdr.width;
  uhdr_compressed_image_t base{};
  base.data = const_cast<std::uint8_t*>(sdr_jpeg.data());
  base.data_sz = base.capacity = sdr_jpeg.size();
  switch (sdr_gamut) {
    case ColorGamut::kSrgb: base.cg = UHDR_CG_BT_709; break;
    case ColorGamut::kDisplayP3: base.cg = UHDR_CG_DISPLAY_P3; break;
    case ColorGamut::kRec2020: base.cg = UHDR_CG_BT_2100; break;
  }
  base.ct = UHDR_CT_SRGB;
  base.range = UHDR_CR_FULL_RANGE;
  std::unique_ptr<uhdr_codec_private_t, EncoderDeleter> encoder(uhdr_create_encoder());
  if (!encoder) throw std::runtime_error("cannot allocate libultrahdr encoder");
  check_uhdr(uhdr_enc_set_raw_image(encoder.get(), &raw, UHDR_HDR_IMG), "set linear HDR pixels");
  // set_raw_image owns a copy; release our potentially full-camera-size buffer
  // before the library allocates its decoded SDR and gain-map working images.
  std::vector<std::uint16_t>().swap(rgba);
  check_uhdr(uhdr_enc_set_compressed_image(encoder.get(), &base, UHDR_SDR_IMG), "set SDR JPEG");
  check_uhdr(uhdr_enc_set_preset(encoder.get(), UHDR_USAGE_BEST_QUALITY), "set gain-map quality preset");
  check_uhdr(uhdr_enc_set_using_multi_channel_gainmap(encoder.get(), 1), "enable RGB gain map");
  check_uhdr(uhdr_enc_set_gainmap_scale_factor(encoder.get(), 1), "set full-resolution gain map");
  check_uhdr(uhdr_enc_set_quality(encoder.get(), gain_quality, UHDR_GAIN_MAP_IMG), "set gain JPEG quality");
  // The v1.4 decoder rejects equal min/max capacity. As with API4, give SDR
  // output a negligible positive interval without changing the HDR pixels.
  check_uhdr(uhdr_enc_set_target_display_peak_brightness(encoder.get(),
      std::clamp(peak_nits, 203.0F * 1.0001F, 10000.0F)),
      "set Ultra HDR display peak");
  check_uhdr(uhdr_encode(encoder.get()), "encode Ultra HDR rendition pair");
  const auto* output = uhdr_get_encoded_stream(encoder.get());
  if (!output || !output->data || output->data_sz == 0) {
    throw std::runtime_error("libultrahdr returned an empty JPEG/R stream");
  }
  // API3 computes gain from the actual compressed base, but its display
  // capacity otherwise remains the requested budget. Repackage the same JPEG
  // payloads with the measured gain maximum, just like the explicit-map path.
  // No pixels are decoded or JPEG-compressed again here.
  std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> probe(uhdr_create_decoder());
  if (!probe) throw std::runtime_error("cannot allocate libultrahdr metadata probe");
  auto generated = *output;
  check_uhdr(uhdr_dec_set_image(probe.get(), &generated), "open generated Ultra HDR metadata");
  check_uhdr(uhdr_dec_probe(probe.get()), "probe generated Ultra HDR metadata");
  const auto* measured = uhdr_dec_get_gainmap_metadata(probe.get());
  const auto* gain_jpeg = uhdr_dec_get_gainmap_image(probe.get());
  if (!measured || !gain_jpeg || !gain_jpeg->data || !gain_jpeg->data_sz)
    throw std::runtime_error("generated Ultra HDR gain metadata is missing");
  auto gain_metadata = *measured;
  gain_metadata.hdr_capacity_max = std::max({gain_metadata.max_content_boost[0],
      gain_metadata.max_content_boost[1], gain_metadata.max_content_boost[2],
      gain_metadata.hdr_capacity_min * 1.0001F});
  uhdr_compressed_image_t gain{};
  gain.data = gain_jpeg->data;
  gain.data_sz = gain.capacity = gain_jpeg->data_sz;
  gain.cg = UHDR_CG_UNSPECIFIED;
  gain.ct = UHDR_CT_UNSPECIFIED;
  gain.range = UHDR_CR_UNSPECIFIED;
  std::unique_ptr<uhdr_codec_private_t, EncoderDeleter> repack(uhdr_create_encoder());
  if (!repack) throw std::runtime_error("cannot allocate libultrahdr repackager");
  check_uhdr(uhdr_enc_set_compressed_image(repack.get(), &base, UHDR_BASE_IMG),
             "reuse Ultra HDR base JPEG");
  check_uhdr(uhdr_enc_set_gainmap_image(repack.get(), &gain, &gain_metadata),
             "set measured Ultra HDR gain capacity");
  check_uhdr(uhdr_encode(repack.get()), "package measured Ultra HDR gain capacity");
  const auto* packaged = uhdr_get_encoded_stream(repack.get());
  if (!packaged || !packaged->data || !packaged->data_sz)
    throw std::runtime_error("libultrahdr returned an empty repackaged JPEG/R stream");
  const auto* begin = static_cast<const std::uint8_t*>(packaged->data);
  return {begin, begin + packaged->data_sz};
}

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const PhotoRenditions& images,
    const PhotoMetadata& metadata, int quality) {
  images.sdr.require_consistent("Ultra HDR SDR rendition");
  if (images.sdr.width != images.hdr.width || images.sdr.height != images.hdr.height) {
    throw std::invalid_argument("Ultra HDR SDR and HDR dimensions must match");
  }
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  const auto base = make_base_jpeg(images.sdr, metadata, quality, images.clamp_srgb, true);
  return encode_ultrahdr_jpeg(images.hdr, base, ColorGamut::kDisplayP3,
      images.stats.headroom_stops, std::max(85, quality));
}

UltraHdrInfo probe_ultrahdr_jpeg(const std::vector<std::uint8_t>& bytes) {
  uhdr_compressed_image_t input{};
  input.data = const_cast<std::uint8_t*>(bytes.data());
  input.data_sz = input.capacity = bytes.size();
  std::unique_ptr<uhdr_codec_private_t, DecoderDeleter> decoder(uhdr_create_decoder());
  if (!decoder) throw std::runtime_error("cannot allocate libultrahdr probe");
  check_uhdr(uhdr_dec_set_image(decoder.get(), &input), "open Ultra HDR JPEG");
  check_uhdr(uhdr_dec_probe(decoder.get()), "probe Ultra HDR JPEG");
  const auto* metadata = uhdr_dec_get_gainmap_metadata(decoder.get());
  if (!metadata) throw std::runtime_error("Ultra HDR JPEG has no gain metadata");
  UltraHdrInfo result;
  result.width = uhdr_dec_get_image_width(decoder.get());
  result.height = uhdr_dec_get_image_height(decoder.get());
  result.gain_width = uhdr_dec_get_gainmap_width(decoder.get());
  result.gain_height = uhdr_dec_get_gainmap_height(decoder.get());
  for (unsigned c = 0; c < 3; ++c) {
    result.gain_min[c] = std::log2(metadata->min_content_boost[c]);
    result.gain_max[c] = std::log2(metadata->max_content_boost[c]);
    result.gamma[c] = metadata->gamma[c];
  }
  result.headroom_stops = std::log2(metadata->hdr_capacity_max);
  return result;
}

std::vector<std::uint8_t> encode_sdr_jpeg(const FloatImage& image,
    const PhotoMetadata& metadata, int quality, ColorGamut gamut) {
  image.require_consistent("SDR JPEG");
  if (image.channels != 3) throw std::invalid_argument("SDR JPEG requires RGB");
  if (gamut != ColorGamut::kSrgb && gamut != ColorGamut::kDisplayP3)
    throw std::invalid_argument("SDR JPEG supports sRGB or Display P3");
  std::vector<std::uint8_t> rgb(image.pixels.size());
  for (std::uint32_t y=0;y<image.height;++y) for (std::uint32_t x=0;x<image.width;++x) {
    const auto i=(static_cast<std::size_t>(y)*image.width+x)*3;
    auto color=fit_linear_p3_gamut(image.pixels[i],image.pixels[i+1],image.pixels[i+2],1.0F,
                                  gamut == ColorGamut::kSrgb);
    if (gamut == ColorGamut::kSrgb) color=linear_p3_to_rec709(color[0],color[1],color[2]);
    for (unsigned c=0;c<3;++c) rgb[i+c]=static_cast<std::uint8_t>(quantize_dithered(srgb_oetf(color[c]),255,x,y,c));
  }
  const auto icc = gamut == ColorGamut::kSrgb ? codec::srgb_profile() : codec::display_p3_profile();
  const auto exif=make_minimal_exif(metadata);
  return compress_jpeg(rgb.data(),image.width,image.height,3,JCS_RGB,quality,&exif,&icc);
}

void verify_sdr_jpeg(const std::vector<std::uint8_t>& bytes) {
  jpeg_decompress_struct info{};
  JpegError error{};
  info.err=jpeg_std_error(&error.base); error.base.error_exit=jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_decompress(&info);
    throw std::runtime_error(std::string("SDR JPEG verification: ")+error.message);
  }
  jpeg_create_decompress(&info);
  jpeg_mem_src(&info,bytes.data(),static_cast<unsigned long>(bytes.size()));
  jpeg_read_header(&info,TRUE);
  jpeg_start_decompress(&info);
  auto row=(*info.mem->alloc_sarray)(reinterpret_cast<j_common_ptr>(&info),JPOOL_IMAGE,
      info.output_width*info.output_components,1);
  while(info.output_scanline<info.output_height) jpeg_read_scanlines(&info,row,1);
  jpeg_finish_decompress(&info); jpeg_destroy_decompress(&info);
}

std::vector<std::uint8_t> encode_ultrahdr_jpeg(const GainMapResult& images,
                                               const PhotoMetadata& metadata, int quality) {
  if (quality < 0 || quality > 100) throw std::invalid_argument("quality must be in [0,100]");
  images.gain_map.require_consistent("Ultra HDR gain map");
  validate_gain_map_metadata(images.metadata);
  const auto channels = gain_map_channel_count(images.metadata);
  if (images.gain_map.channels != channels) {
    throw std::invalid_argument("Ultra HDR gain pixels and metadata must have matching channels");
  }
  // A full-resolution gain map exists to put every HDR pixel back where it was
  // (an HDR source's own highlights). Subsampling the base's chroma would throw
  // away half of the colour resolution that map multiplies, which measured on a
  // Sony HLG frame as most of the remaining error at saturated highlight edges.
  // A mathematical map is low-frequency and keeps the smaller 4:2:0 base.
  const bool full_resolution_gain = images.gain_map.width == images.base_linear.width &&
                                     images.gain_map.height == images.base_linear.height;
  auto base_bytes = make_base_jpeg(images.base_linear, metadata, quality,
                                   images.clamp_srgb, full_resolution_gain);
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
  for (unsigned c = 0; c < 3; ++c) {
    const auto channel = gain_map_channel(images.metadata, channels == 1 ? 0 : c);
    gain_metadata.min_content_boost[c] = boost_from_stops(value(channel.gain_min));
    gain_metadata.max_content_boost[c] = boost_from_stops(value(channel.gain_max));
    gain_metadata.gamma[c] = value(channel.gamma);
    gain_metadata.offset_sdr[c] = value(channel.base_offset);
    gain_metadata.offset_hdr[c] = value(channel.alternate_offset);
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
  const auto* icc = uhdr_dec_get_icc(decoder.get());
  if (uhdr_dec_get_image_width(decoder.get()) <= 0 ||
      uhdr_dec_get_image_height(decoder.get()) <= 0 ||
      uhdr_dec_get_gainmap_width(decoder.get()) <= 0 ||
      uhdr_dec_get_gainmap_height(decoder.get()) <= 0 ||
      !uhdr_dec_get_gainmap_metadata(decoder.get()) || !icc || !icc->data || icc->data_sz == 0) {
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
