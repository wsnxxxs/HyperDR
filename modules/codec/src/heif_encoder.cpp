#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"

#include <libheif/heif.h>
#include <libheif/heif_tiling.h>
#include <lcms2.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>
#include <memory>
#include <numeric>
#include <stdexcept>
#include <string>

namespace hyperdr {
namespace {

void check_heif(heif_error error, const char* operation) {
  if (error.code != heif_error_Ok) throw std::runtime_error(std::string(operation) + ": " + (error.message ? error.message : "unknown libheif error"));
}

std::vector<std::uint8_t> display_p3_profile(bool linear = false) {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{{0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}};
  double parameters[]{2.4, 1.0 / 1.055, 0.055 / 1.055, 0.0, 0.04045, 1.0 / 12.92, 0.0};
  cmsToneCurve* curve = linear ? cmsBuildGamma(nullptr, 1.0)
                               : cmsBuildParametricToneCurve(nullptr, 4, parameters);
  if (!curve) throw std::runtime_error("cannot build Display P3 tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  cmsHPROFILE profile = cmsCreateRGBProfile(&white, &primaries, curves);
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot create Display P3 ICC profile");
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(profile, nullptr, &size) || size == 0) { cmsCloseProfile(profile); throw std::runtime_error("cannot size ICC profile"); }
  std::vector<std::uint8_t> data(size);
  if (!cmsSaveProfileToMem(profile, data.data(), &size)) { cmsCloseProfile(profile); throw std::runtime_error("cannot serialize ICC profile"); }
  cmsCloseProfile(profile);
  data.resize(size);
  return data;
}

struct ImageDeleter { void operator()(heif_image* p) const { if (p) heif_image_release(p); } };
struct HandleDeleter { void operator()(heif_image_handle* p) const { if (p) heif_image_handle_release(p); } };
struct EncoderDeleter { void operator()(heif_encoder* p) const { if (p) heif_encoder_release(p); } };
struct ContextDeleter { void operator()(heif_context* p) const { if (p) heif_context_free(p); } };
struct EncodingOptionsDeleter { void operator()(heif_encoding_options* p) const { if (p) heif_encoding_options_free(p); } };
struct DecodingOptionsDeleter { void operator()(heif_decoding_options* p) const { if (p) heif_decoding_options_free(p); } };

heif_color_profile_nclx display_p3_nclx() {
  heif_color_profile_nclx nclx{};
  nclx.version = 1;
  nclx.color_primaries = heif_color_primaries_SMPTE_EG_432_1;
  nclx.transfer_characteristics = heif_transfer_characteristic_IEC_61966_2_1;
  nclx.matrix_coefficients = heif_matrix_coefficients_ITU_R_BT_709_5;
  nclx.full_range_flag = 1;
  return nclx;
}

heif_color_profile_nclx gain_map_nclx() {
  heif_color_profile_nclx nclx{};
  nclx.version = 1;
  nclx.color_primaries = heif_color_primaries_unspecified;
  nclx.transfer_characteristics = heif_transfer_characteristic_unspecified;
  nclx.matrix_coefficients = heif_matrix_coefficients_ITU_R_BT_709_5;
  nclx.full_range_flag = 1;
  return nclx;
}

heif_color_profile_nclx bt2100_nclx(HdrEncoding encoding) {
  if (encoding != HdrEncoding::Pq && encoding != HdrEncoding::Hlg) {
    throw std::invalid_argument("BT.2100 profile requires PQ or HLG encoding");
  }
  heif_color_profile_nclx nclx{};
  nclx.version = 1;
  nclx.color_primaries = heif_color_primaries_ITU_R_BT_2020_2_and_2100_0;
  nclx.transfer_characteristics = encoding == HdrEncoding::Pq
      ? heif_transfer_characteristic_ITU_R_BT_2100_0_PQ
      : heif_transfer_characteristic_ITU_R_BT_2100_0_HLG;
  // Match Apple's still-image HEIC signalling in the supplied references.
  nclx.matrix_coefficients = heif_matrix_coefficients_ITU_R_BT_709_5;
  nclx.full_range_flag = 1;
  return nclx;
}

void validate_base_profile(const heif_image_handle* handle) {
  heif_color_profile_nclx* nclx = nullptr;
  const auto error = heif_image_handle_get_nclx_color_profile(handle, &nclx);
  const bool has_icc = heif_image_handle_get_raw_color_profile_size(handle) > 0;
  const bool has_nclx = nclx != nullptr;
  const bool valid_nclx = error.code == heif_error_Ok && nclx &&
                          (nclx->color_primaries == heif_color_primaries_SMPTE_EG_432_1 ||
                           nclx->color_primaries == heif_color_primaries_ITU_R_BT_709_5 ||
                           nclx->color_primaries == heif_color_primaries_unspecified) &&
                          (nclx->transfer_characteristics ==
                               heif_transfer_characteristic_IEC_61966_2_1 ||
                           nclx->transfer_characteristics ==
                               heif_transfer_characteristic_ITU_R_BT_709_5 ||
                           nclx->transfer_characteristics ==
                               heif_transfer_characteristic_unspecified) &&
                          (nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 ||
                           nclx->matrix_coefficients == heif_matrix_coefficients_unspecified) &&
                          nclx->full_range_flag == 1;
  if (nclx) heif_nclx_color_profile_free(nclx);
  // Apple files in the wild use either an ICC-only Display-P3 profile or an
  // nclx-only BT.709/sRGB profile. Both are valid SDR bases for the verified
  // single-channel forward subset; HyperDR-produced files still carry both.
  // A nclx-only Apple base may be exposed by libheif as an unavailable
  // profile (the property is attached through ipma). The HEIF structural
  // inspection has already validated the item graph, so absence of an ICC is
  // not grounds to reject that legal source. When an ICC is present, however,
  // an explicitly present nclx must still be internally consistent.
  if (has_icc && has_nclx && !valid_nclx) {
    throw std::runtime_error("SDR base lacks a usable ICC or nclx SDR profile");
  }
}

void validate_gain_profile(const heif_image_handle* handle) {
  heif_color_profile_nclx* nclx = nullptr;
  const auto error = heif_image_handle_get_nclx_color_profile(handle, &nclx);
  // Apple's gain-map item is often deliberately unprofiled; the metadata
  // carries the ISO interpretation and the image is an 8-bit luma plane.
  // HyperDR-produced files do carry the strict unspecified/BT.709 nclx below,
  // so an explicitly present profile is still checked rather than ignored.
  const bool valid = error.code != heif_error_Ok || nclx == nullptr ||
                     (nclx->color_primaries == heif_color_primaries_unspecified &&
                      nclx->transfer_characteristics ==
                          heif_transfer_characteristic_unspecified &&
                      nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 &&
                      nclx->full_range_flag == 1);
  if (nclx) heif_nclx_color_profile_free(nclx);
  if (!valid) throw std::runtime_error("Gain Map lacks required nclx 2/2/1/full");
}

std::unique_ptr<heif_image, ImageDeleter> make_base(const FloatImage& image, int depth) {
  if (depth != 8 && depth != 10) throw std::invalid_argument("base depth must be 8 or 10");
  heif_image* raw = nullptr;
  const auto chroma = depth > 8 ? heif_chroma_interleaved_RRGGBB_LE : heif_chroma_interleaved_RGB;
  check_heif(heif_image_create(static_cast<int>(image.width), static_cast<int>(image.height), heif_colorspace_RGB,
                               chroma, &raw), "create base image");
  std::unique_ptr<heif_image, ImageDeleter> result(raw);
  check_heif(heif_image_add_plane(raw, heif_channel_interleaved, image.width, image.height, depth), "allocate base plane");
  int stride = 0;
  auto* plane = heif_image_get_plane(raw, heif_channel_interleaved, &stride);
  if (!plane || stride <= 0) throw std::runtime_error("allocated base plane is unavailable");
  // TPDF-dithered quantization removes visible banding in smooth gradients
  // (skies) that the multiplicative gain map would otherwise amplify.
  const unsigned max_code = (1U << depth) - 1U;
  parallel_for_rows(image.height, [&](const std::uint32_t y) {
    if (depth > 8) {
      auto* row = reinterpret_cast<std::uint16_t*>(plane + static_cast<std::size_t>(y) * stride);
      for (std::uint32_t x = 0; x < image.width; ++x) {
        for (unsigned c = 0; c < 3; ++c) {
          row[x * 3 + c] = static_cast<std::uint16_t>(
              quantize_dithered(srgb_oetf(image.at(x, y, c)), max_code, x, y, c));
        }
      }
    } else {
      auto* row = plane + static_cast<std::size_t>(y) * stride;
      for (std::uint32_t x = 0; x < image.width; ++x) {
        for (unsigned c = 0; c < 3; ++c) {
          row[x * 3 + c] = static_cast<std::uint8_t>(
              quantize_dithered(srgb_oetf(image.at(x, y, c)), max_code, x, y, c));
        }
      }
    }
  });
  auto nclx = display_p3_nclx();
  check_heif(heif_image_set_nclx_color_profile(raw, &nclx), "set P3 nclx");
  const auto icc = display_p3_profile();
  check_heif(heif_image_set_raw_color_profile(raw, "prof", icc.data(), icc.size()), "set P3 ICC");
  return result;
}

// The gain map is encoded as 8-bit 4:2:0 YCbCr with neutral chroma instead of true
// 4:0:0 monochrome: x265 signals monochrome with the format-range-extensions profile
// (general_profile_idc 4), which is far less widely decodable than plain Main profile,
// notably on iOS hardware decoders. Neutral-chroma 4:2:0 costs a few kilobytes and
// keeps the stream in baseline Main/Main Still Picture territory.
std::unique_ptr<heif_image, ImageDeleter> make_gain(const FloatImage& image) {
  heif_image* raw = nullptr;
  check_heif(heif_image_create(static_cast<int>(image.width), static_cast<int>(image.height),
                               heif_colorspace_YCbCr, heif_chroma_420, &raw), "create gain map");
  std::unique_ptr<heif_image, ImageDeleter> result(raw);
  check_heif(heif_image_add_plane(raw, heif_channel_Y, static_cast<int>(image.width), static_cast<int>(image.height), 8), "allocate gain luma plane");
  const auto chroma_width = (image.width + 1) / 2;
  const auto chroma_height = (image.height + 1) / 2;
  check_heif(heif_image_add_plane(raw, heif_channel_Cb, static_cast<int>(chroma_width), static_cast<int>(chroma_height), 8), "allocate gain Cb plane");
  check_heif(heif_image_add_plane(raw, heif_channel_Cr, static_cast<int>(chroma_width), static_cast<int>(chroma_height), 8), "allocate gain Cr plane");
  int stride = 0;
  auto* plane = heif_image_get_plane(raw, heif_channel_Y, &stride);
  if (!plane || stride <= 0) throw std::runtime_error("allocated gain luma plane is unavailable");
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = 0; x < image.width; ++x)
      plane[static_cast<std::size_t>(y) * stride + x] = static_cast<std::uint8_t>(std::lround(std::clamp(image.at(x, y, 0), 0.0F, 1.0F) * 255.0F));
  }
  for (const auto channel : {heif_channel_Cb, heif_channel_Cr}) {
    int chroma_stride = 0;
    auto* chroma_plane = heif_image_get_plane(raw, channel, &chroma_stride);
    if (!chroma_plane || chroma_stride <= 0) {
      throw std::runtime_error("allocated gain chroma plane is unavailable");
    }
    for (std::uint32_t y = 0; y < chroma_height; ++y)
      std::memset(chroma_plane + static_cast<std::size_t>(y) * chroma_stride, 128, chroma_width);
  }
  // ISO 21496-1 gain-map inputs require explicit nclx signalling. Primaries and
  // transfer are intentionally unspecified because samples represent gain, not
  // colour; matrix/range describe the actual 4:2:0 encoding transform.
  auto nclx = gain_map_nclx();
  check_heif(heif_image_set_nclx_color_profile(raw, &nclx), "set gain map nclx");
  return result;
}

std::unique_ptr<heif_image, ImageDeleter> make_hdr(
    const GainMapResult& images, HdrEncoding encoding,
    heif_content_light_level& light_level) {
  constexpr int depth = 10;
  auto hdr = reconstruct_gain_map(images.base_linear, images.gain_map, images.metadata,
                                  images.headroom_stops);
  heif_image* raw = nullptr;
  check_heif(heif_image_create(static_cast<int>(hdr.width), static_cast<int>(hdr.height),
                               heif_colorspace_RGB, heif_chroma_interleaved_RRGGBB_LE,
                               &raw),
             "create BT.2100 HDR image");
  std::unique_ptr<heif_image, ImageDeleter> result(raw);
  check_heif(heif_image_add_plane(raw, heif_channel_interleaved, hdr.width, hdr.height,
                                  depth),
             "allocate BT.2100 HDR plane");
  int stride = 0;
  auto* plane = heif_image_get_plane(raw, heif_channel_interleaved, &stride);
  if (!plane || stride <= 0) throw std::runtime_error("allocated HDR plane is unavailable");

  constexpr unsigned max_code = (1U << depth) - 1U;
  std::vector<float> row_peak(hdr.height, 0.0F);
  std::vector<double> row_luminance(hdr.height, 0.0);
  parallel_for_rows(hdr.height, [&](const std::uint32_t y) {
    auto* row = reinterpret_cast<std::uint16_t*>(
        plane + static_cast<std::size_t>(y) * stride);
    float peak = 0.0F;
    double luminance_sum = 0.0;
    for (std::uint32_t x = 0; x < hdr.width; ++x) {
      const auto rgb = p3_to_rec2020(hdr.at(x, y, 0), hdr.at(x, y, 1), hdr.at(x, y, 2));
      const std::array<float, 3> linear{
          std::max(0.0F, rgb[0]), std::max(0.0F, rgb[1]), std::max(0.0F, rgb[2])};
      peak = std::max(peak, std::max({linear[0], linear[1], linear[2]}));
      luminance_sum += 0.2627 * linear[0] + 0.6780 * linear[1] + 0.0593 * linear[2];
      for (unsigned channel = 0; channel < 3; ++channel) {
        const float encoded = encoding == HdrEncoding::Pq
                                  ? pq_oetf(linear[channel])
                                  : hlg_oetf(linear[channel]);
        row[x * 3 + channel] = static_cast<std::uint16_t>(
            quantize_dithered(encoded, max_code, x, y, channel));
      }
    }
    row_peak[y] = peak;
    row_luminance[y] = luminance_sum;
  });

  const float peak = *std::max_element(row_peak.begin(), row_peak.end());
  const double luminance_sum = std::accumulate(row_luminance.begin(), row_luminance.end(), 0.0);
  const double pixel_count = static_cast<double>(hdr.width) * hdr.height;
  const auto clamp_light = [](double nits) {
    return static_cast<std::uint16_t>(std::clamp(std::ceil(nits), 0.0, 10000.0));
  };
  light_level.max_content_light_level = clamp_light(peak * kReferenceWhiteNits);
  light_level.max_pic_average_light_level =
      clamp_light(pixel_count > 0.0 ? luminance_sum * kReferenceWhiteNits / pixel_count : 0.0);
  heif_image_set_content_light_level(raw, &light_level);
  auto nclx = bt2100_nclx(encoding);
  check_heif(heif_image_set_nclx_color_profile(raw, &nclx), "set BT.2100 nclx");
  return result;
}

std::unique_ptr<heif_image_handle, HandleDeleter> encode_base(
    heif_context* context, heif_image* image, heif_encoder* encoder,
    std::uint32_t width, std::uint32_t height) {
  // x265 emits each picture as a single slice NAL, and libde265 (used by libheif,
  // heif-convert, and most desktop HEIF consumers) rejects NAL units larger than its
  // 16 MiB security limit. A 24 MP quality-90 photo already produces a ~18 MB slice,
  // so anything beyond one tile is encoded as a grid of 2048-px tiles: at typical
  // photographic bitrates a tile stays in the low megabytes even at quality 100.
  // Apple's own camera HEICs are grids as well, so this is the well-trodden path.
  constexpr std::uint32_t tile_size = 2048;
  std::unique_ptr<heif_encoding_options, EncodingOptionsDeleter> options(
      heif_encoding_options_alloc());
  if (!options) throw std::runtime_error("cannot allocate HEIF encoding options");
  auto nclx = display_p3_nclx();
  options->save_two_colr_boxes_when_ICC_and_nclx_available = 1;
  options->output_nclx_profile = &nclx;
  heif_image_handle* handle_raw = nullptr;
  if (width <= tile_size && height <= tile_size) {
    check_heif(heif_context_encode_image(context, image, encoder, options.get(), &handle_raw), "encode base");
    return std::unique_ptr<heif_image_handle, HandleDeleter>(handle_raw);
  }

  const auto columns = (width + tile_size - 1) / tile_size;
  const auto rows = (height + tile_size - 1) / tile_size;
  check_heif(heif_context_add_grid_image(context, width, height, columns, rows,
                                         options.get(), &handle_raw),
             "create base grid");
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_raw);
  for (std::uint32_t y = 0; y < rows; ++y) {
    for (std::uint32_t x = 0; x < columns; ++x) {
      heif_image* tile_raw = nullptr;
      check_heif(heif_image_extract_area(image,
                                         static_cast<int>(x * tile_size),
                                         static_cast<int>(y * tile_size),
                                         static_cast<int>(tile_size),
                                         static_cast<int>(tile_size),
                                         nullptr, &tile_raw),
                 "extract base tile");
      std::unique_ptr<heif_image, ImageDeleter> tile(tile_raw);
      check_heif(heif_context_add_image_tile(context, handle.get(), x, y,
                                             tile.get(), encoder),
                 "encode base tile");
    }
  }
  return handle;
}

std::unique_ptr<heif_image_handle, HandleDeleter> encode_hdr_image(
    heif_context* context, heif_image* image, heif_encoder* encoder,
    std::uint32_t width, std::uint32_t height, HdrEncoding encoding,
    const heif_content_light_level& light_level) {
  constexpr std::uint32_t tile_size = 2048;
  std::unique_ptr<heif_encoding_options, EncodingOptionsDeleter> options(
      heif_encoding_options_alloc());
  if (!options) throw std::runtime_error("cannot allocate HDR encoding options");
  auto nclx = bt2100_nclx(encoding);
  options->output_nclx_profile = &nclx;
  heif_image_handle* handle_raw = nullptr;
  if (width <= tile_size && height <= tile_size) {
    check_heif(heif_context_encode_image(context, image, encoder, options.get(), &handle_raw),
               "encode BT.2100 HDR image");
    std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_raw);
    heif_image_handle_set_content_light_level(handle.get(), &light_level);
    return handle;
  }

  const auto columns = (width + tile_size - 1) / tile_size;
  const auto rows = (height + tile_size - 1) / tile_size;
  check_heif(heif_context_add_grid_image(context, width, height, columns, rows,
                                         options.get(), &handle_raw),
             "create BT.2100 HDR grid");
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_raw);
  heif_image_handle_set_content_light_level(handle.get(), &light_level);
  for (std::uint32_t y = 0; y < rows; ++y) {
    for (std::uint32_t x = 0; x < columns; ++x) {
      heif_image* tile_raw = nullptr;
      check_heif(heif_image_extract_area(image, static_cast<int>(x * tile_size),
                                         static_cast<int>(y * tile_size),
                                         static_cast<int>(tile_size),
                                         static_cast<int>(tile_size), nullptr, &tile_raw),
                 "extract BT.2100 HDR tile");
      std::unique_ptr<heif_image, ImageDeleter> tile(tile_raw);
      check_heif(heif_context_add_image_tile(context, handle.get(), x, y, tile.get(), encoder),
                 "encode BT.2100 HDR tile");
    }
  }
  return handle;
}
heif_error write_callback(heif_context*, const void* data, size_t size, void* user) {
  try {
    auto& bytes = *static_cast<std::vector<std::uint8_t>*>(user);
    const auto* begin = static_cast<const std::uint8_t*>(data);
    bytes.insert(bytes.end(), begin, begin + size);
    return {heif_error_Ok, heif_suberror_Unspecified, "Success"};
  } catch (...) {
    // Never allow a C++ exception to cross libheif's C callback boundary.
    return {heif_error_Encoding_error, heif_suberror_Unspecified,
            "cannot grow HEIF output buffer"};
  }
}

}  // namespace

std::vector<std::uint8_t> encode_adaptive_heic(const GainMapResult& images,
                                               const PhotoMetadata& metadata, int quality,
                                               int depth) {
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate libheif context");
  heif_encoder* encoder_raw = nullptr;
  check_heif(heif_context_get_encoder_for_format(context.get(), heif_compression_HEVC, &encoder_raw), "get HEVC encoder");
  std::unique_ptr<heif_encoder, EncoderDeleter> encoder(encoder_raw);
  check_heif(heif_encoder_set_lossy_quality(encoder.get(), std::clamp(quality, 0, 100)), "set HEVC quality");
  heif_encoder* gain_encoder_raw = nullptr;
  check_heif(heif_context_get_encoder_for_format(context.get(), heif_compression_HEVC,
                                                  &gain_encoder_raw), "get Gain Map HEVC encoder");
  std::unique_ptr<heif_encoder, EncoderDeleter> gain_encoder(gain_encoder_raw);
  check_heif(heif_encoder_set_lossless(gain_encoder.get(), 1),
             "set Gain Map HEVC lossless");

  auto base = make_base(images.base_linear, depth);
  auto gain = make_gain(images.gain_map);
  heif_image_handle* gain_handle_raw = nullptr;
  // Explicit encoding options are required for libheif to carry the gain-map
  // nclx profile into the encoded item.
  std::unique_ptr<heif_encoding_options, EncodingOptionsDeleter> gain_options(
      heif_encoding_options_alloc());
  if (!gain_options) throw std::runtime_error("cannot allocate gain-map encoding options");
  auto gain_nclx = gain_map_nclx();
  gain_options->output_nclx_profile = &gain_nclx;
  // Encode the visible gain image first. Grid encoding creates hidden HEVC tile
  // items; keeping the gain item first makes the narrow TMAP adapter unambiguous.
  check_heif(heif_context_encode_image(context.get(), gain.get(), gain_encoder.get(),
                                       gain_options.get(), &gain_handle_raw),
             "encode gain map");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  auto base_handle = encode_base(context.get(), base.get(), encoder.get(),
                                 images.base_linear.width, images.base_linear.height);
  check_heif(heif_context_set_primary_image(context.get(), base_handle.get()), "set primary image");

  const auto exif = make_minimal_exif(metadata);
  check_heif(heif_context_add_exif_metadata(context.get(), base_handle.get(), exif.data(), static_cast<int>(exif.size())), "add Exif");
  const auto xmp = make_xmp(metadata, images.headroom_stops);
  check_heif(heif_context_add_XMP_metadata(context.get(), base_handle.get(), xmp.data(), static_cast<int>(xmp.size())), "add XMP");

  std::vector<std::uint8_t> intermediate;
  heif_writer writer{1, &write_callback};
  check_heif(heif_context_write(context.get(), &writer, &intermediate), "write HEIC");
  return add_tmap_to_two_image_heif(intermediate, serialize_tmap_payload(images.metadata));
}

std::vector<std::uint8_t> encode_hdr_heic(const GainMapResult& images,
                                          const PhotoMetadata& metadata, int quality,
                                          HdrEncoding encoding) {
  if (encoding != HdrEncoding::Pq && encoding != HdrEncoding::Hlg) {
    throw std::invalid_argument("encode_hdr_heic requires PQ or HLG");
  }
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate libheif context");
  heif_encoder* encoder_raw = nullptr;
  check_heif(heif_context_get_encoder_for_format(context.get(), heif_compression_HEVC,
                                                  &encoder_raw),
             "get HDR HEVC encoder");
  std::unique_ptr<heif_encoder, EncoderDeleter> encoder(encoder_raw);
  check_heif(heif_encoder_set_lossy_quality(encoder.get(), std::clamp(quality, 0, 100)),
             "set HDR HEVC quality");

  heif_content_light_level light_level{};
  auto image = make_hdr(images, encoding, light_level);
  auto handle = encode_hdr_image(context.get(), image.get(), encoder.get(),
                                 images.base_linear.width, images.base_linear.height,
                                 encoding, light_level);
  check_heif(heif_context_set_primary_image(context.get(), handle.get()),
             "set HDR primary image");
  const auto exif = make_minimal_exif(metadata);
  check_heif(heif_context_add_exif_metadata(context.get(), handle.get(), exif.data(),
                                             static_cast<int>(exif.size())),
             "add HDR Exif");
  const auto xmp = make_xmp(metadata, images.headroom_stops);
  check_heif(heif_context_add_XMP_metadata(context.get(), handle.get(), xmp.data(),
                                            static_cast<int>(xmp.size())),
             "add HDR XMP");
  std::vector<std::uint8_t> bytes;
  heif_writer writer{1, &write_callback};
  check_heif(heif_context_write(context.get(), &writer, &bytes), "write BT.2100 HEIC");
  return bytes;
}

void verify_heic_decodable(const std::vector<std::uint8_t>& bytes) {
  // Every check below already passed on a file that macOS ImageIO refused to
  // recognise as carrying a gain map at all (gate T2, 2026-08-09,
  // HyperDR_Model/reports/macos-t2-container-finding.md). Structural
  // self-consistency was never the same property as being readable by an
  // independent decoder, so the three conformance requirements that file lacked
  // are gated here as well, where they constrain what this writer emits.
  const auto inspection = inspect_heif(bytes);
  const bool auxiliary_declared =
      inspection.gain_map_auxiliary_type == "urn:iso:std:iso:ts:21496:-1";
  if (!inspection.structurally_valid || !inspection.has_heic_brand ||
      !inspection.has_tmap_brand || !inspection.has_tmap_item ||
      !inspection.has_dimg_reference || !inspection.has_altr_group ||
      !inspection.has_data_information || !inspection.gain_map_has_auxl_reference ||
      !auxiliary_declared) {
    // inspect_heif reports a failed check as a cleared flag and puts the reason
    // in `errors`, so a message built only from the flags describes the symptom
    // and hides the cause. A rejected gain-map payload, for instance, clears
    // structurally_valid and used to surface as nothing but "failed semantic
    // structure verification" -- true, and no help at all in finding out why.
    std::string reason = "Adaptive HDR HEIC failed semantic structure verification:";
    const auto note = [&reason](bool ok, const char* what) {
      if (!ok) reason += std::string(" no ") + what + ";";
    };
    note(inspection.has_heic_brand, "heic brand");
    note(inspection.has_tmap_brand, "tmap brand");
    note(inspection.has_tmap_item, "tmap item");
    note(inspection.has_dimg_reference, "dimg reference");
    note(inspection.has_altr_group, "altr group");
    note(inspection.has_data_information, "dinf box");
    note(inspection.gain_map_has_auxl_reference, "auxl reference from the gain map");
    note(auxiliary_declared, "ISO 21496-1 auxiliary type on the gain map");
    for (const auto& error : inspection.errors) reason += " " + error + ";";
    if (inspection.errors.empty() && inspection.structurally_valid) {
      reason += " no further detail was reported";
    }
    throw std::runtime_error(reason);
  }
  (void)parse_tmap_payload(extract_tmap_payload(bytes));
  const auto references = find_tmap_references(bytes);

  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate verification context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read Adaptive HDR HEIC");

  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  validate_base_profile(primary.get());
  if (heif_image_handle_get_item_id(primary.get()) != references.base_id) {
    throw std::runtime_error("tmap base reference is not the primary image");
  }

  const bool wide = heif_image_handle_get_luma_bits_per_pixel(primary.get()) > 8;
  heif_image* base_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &base_raw, heif_colorspace_RGB,
                               wide ? heif_chroma_interleaved_RRGGBB_LE
                                    : heif_chroma_interleaved_RGB,
                               nullptr),
             "decode SDR base");
  std::unique_ptr<heif_image, ImageDeleter> base(base_raw);
  const int base_width = heif_image_get_width(base.get(), heif_channel_interleaved);
  const int base_height = heif_image_get_height(base.get(), heif_channel_interleaved);
  if (base_width <= 0 || base_height <= 0) {
    throw std::runtime_error("decoded SDR base has invalid dimensions");
  }

  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context.get(), references.gain_id,
                                           &gain_handle_raw),
             "get Gain Map image handle");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  heif_color_profile_nclx* gain_profile_raw = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(
                 gain_handle.get(), &gain_profile_raw),
             "get Gain Map nclx");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      gain_profile(gain_profile_raw, &heif_nclx_color_profile_free);
  if (gain_profile->color_primaries != heif_color_primaries_unspecified ||
      gain_profile->transfer_characteristics !=
          heif_transfer_characteristic_unspecified ||
      gain_profile->matrix_coefficients !=
          heif_matrix_coefficients_ITU_R_BT_709_5 ||
      gain_profile->full_range_flag != 1) {
    throw std::runtime_error("Gain Map nclx must be 2/2/BT.709/full-range");
  }

  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw,
                               heif_colorspace_YCbCr, heif_chroma_420, nullptr),
             "decode Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain(gain_raw);
  const int gain_width = heif_image_get_width(gain.get(), heif_channel_Y);
  const int gain_height = heif_image_get_height(gain.get(), heif_channel_Y);
  if (gain_width <= 0 || gain_height <= 0 || gain_width > base_width ||
      gain_height > base_height ||
      heif_image_get_bits_per_pixel_range(gain.get(), heif_channel_Y) != 8) {
    throw std::runtime_error("decoded Gain Map has invalid dimensions or depth");
  }
  int y_stride = 0;
  if (!heif_image_get_plane_readonly(gain.get(), heif_channel_Y, &y_stride) ||
      y_stride < gain_width) {
    throw std::runtime_error("decoded Gain Map luma plane is unavailable");
  }
}

void verify_heic_decodable(const std::vector<std::uint8_t>& bytes,
                           HdrEncoding encoding) {
  if (encoding == HdrEncoding::Adaptive) {
    verify_heic_decodable(bytes);
    return;
  }
  const auto inspection = inspect_heif(bytes);
  if (!inspection.structurally_valid || !inspection.has_heic_brand ||
      inspection.has_tmap_item) {
    throw std::runtime_error("BT.2100 HEIC failed semantic structure verification");
  }
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HDR verification context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read BT.2100 HEIC");
  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get BT.2100 primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);

  heif_color_profile_nclx* profile_raw = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(primary.get(), &profile_raw),
             "get BT.2100 nclx");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      profile(profile_raw, &heif_nclx_color_profile_free);
  const auto expected_transfer = encoding == HdrEncoding::Pq
      ? heif_transfer_characteristic_ITU_R_BT_2100_0_PQ
      : heif_transfer_characteristic_ITU_R_BT_2100_0_HLG;
  if (profile->color_primaries !=
          heif_color_primaries_ITU_R_BT_2020_2_and_2100_0 ||
      profile->transfer_characteristics != expected_transfer ||
      profile->matrix_coefficients != heif_matrix_coefficients_ITU_R_BT_709_5 ||
      profile->full_range_flag != 1) {
    throw std::runtime_error("BT.2100 HEIC has incorrect nclx signalling");
  }
  heif_content_light_level light{};
  if (!heif_image_handle_get_content_light_level(primary.get(), &light)) {
    throw std::runtime_error("BT.2100 HEIC lacks content-light metadata");
  }

  std::unique_ptr<heif_decoding_options, DecodingOptionsDeleter> options(
      heif_decoding_options_alloc());
  if (!options) throw std::runtime_error("cannot allocate HDR decoding options");
  options->output_image_nclx_profile_passthrough = 1;
  heif_image* decoded_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &decoded_raw, heif_colorspace_RGB,
                               heif_chroma_interleaved_RRGGBB_LE, options.get()),
             "decode BT.2100 HDR image");
  std::unique_ptr<heif_image, ImageDeleter> decoded(decoded_raw);
  if (heif_image_get_width(decoded.get(), heif_channel_interleaved) <= 0 ||
      heif_image_get_height(decoded.get(), heif_channel_interleaved) <= 0 ||
      heif_image_get_bits_per_pixel_range(decoded.get(), heif_channel_interleaved) != 10) {
    throw std::runtime_error("decoded BT.2100 image is not valid 10-bit RGB");
  }
}

void verify_heic_decodable(const std::filesystem::path& input) {
  const auto bytes = read_binary_file(input);
  const auto inspection = inspect_heif(bytes);
  if (inspection.has_tmap_brand || inspection.has_tmap_item) {
    verify_heic_decodable(bytes);
    return;
  }
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HEIC detection context");
  check_heif(heif_context_read_from_memory_without_copy(
                 context.get(), bytes.data(), bytes.size(), nullptr),
             "read HEIC for HDR mode detection");
  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw),
             "get image for HDR mode detection");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  heif_color_profile_nclx* profile_raw = nullptr;
  check_heif(heif_image_handle_get_nclx_color_profile(primary.get(), &profile_raw),
             "get nclx for HDR mode detection");
  std::unique_ptr<heif_color_profile_nclx, decltype(&heif_nclx_color_profile_free)>
      profile(profile_raw, &heif_nclx_color_profile_free);
  if (profile->transfer_characteristics == heif_transfer_characteristic_ITU_R_BT_2100_0_PQ) {
    verify_heic_decodable(bytes, HdrEncoding::Pq);
  } else if (profile->transfer_characteristics ==
             heif_transfer_characteristic_ITU_R_BT_2100_0_HLG) {
    verify_heic_decodable(bytes, HdrEncoding::Hlg);
  } else {
    throw std::runtime_error("HEIC is neither Adaptive HDR, PQ, nor HLG");
  }
}

void reconstruct_heic_to_tiff(const std::filesystem::path& input,
                              const std::filesystem::path& output) {
  const auto bytes = read_binary_file(input);
  const auto metadata = parse_tmap_payload(extract_tmap_payload(bytes));
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate libheif context");
  check_heif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr),
             "read Adaptive HDR HEIC");

  heif_image_handle* primary_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &primary_raw), "get primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> primary(primary_raw);
  validate_base_profile(primary.get());
  const bool wide_base = heif_image_handle_get_luma_bits_per_pixel(primary.get()) > 8;
  heif_image* base_raw = nullptr;
  check_heif(heif_decode_image(primary.get(), &base_raw, heif_colorspace_RGB,
                               wide_base ? heif_chroma_interleaved_RRGGBB_LE : heif_chroma_interleaved_RGB,
                               nullptr), "decode SDR base");
  std::unique_ptr<heif_image, ImageDeleter> base_image(base_raw);

  // The Gain Map is the second dimg reference of the tmap item; scanning for "any
  // decodable non-primary item" would wrongly pick a hidden grid tile instead.
  const auto references = find_tmap_references(bytes);
  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context.get(), references.gain_id, &gain_handle_raw),
             "get Gain Map image handle");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  validate_gain_profile(gain_handle.get());
  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw, heif_colorspace_undefined,
                               heif_chroma_undefined, nullptr), "decode Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);

  const auto width = static_cast<std::uint32_t>(heif_image_get_width(base_image.get(), heif_channel_interleaved));
  const auto height = static_cast<std::uint32_t>(heif_image_get_height(base_image.get(), heif_channel_interleaved));
  const auto gain_width = static_cast<std::uint32_t>(heif_image_get_width(gain_image.get(), heif_channel_Y));
  const auto gain_height = static_cast<std::uint32_t>(heif_image_get_height(gain_image.get(), heif_channel_Y));
  FloatImage base(width, height, 3), gain(gain_width, gain_height, 1);
  int base_stride = 0, gain_stride = 0;
  const auto* base_plane = heif_image_get_plane_readonly(base_image.get(), heif_channel_interleaved, &base_stride);
  const auto* gain_plane = heif_image_get_plane_readonly(gain_image.get(), heif_channel_Y, &gain_stride);
  if (!base_plane || !gain_plane) throw std::runtime_error("decoded HEIC plane is missing");
  const int base_bits = heif_image_get_bits_per_pixel_range(base_image.get(), heif_channel_interleaved);
  const int gain_bits = heif_image_get_bits_per_pixel_range(gain_image.get(), heif_channel_Y);
  const float base_max = static_cast<float>((1U << std::min(base_bits, 16)) - 1U);
  const float gain_max = static_cast<float>((1U << std::min(gain_bits, 16)) - 1U);
  for (std::uint32_t y = 0; y < height; ++y) {
    if (base_bits > 8) {
      const auto* row = reinterpret_cast<const std::uint16_t*>(base_plane + static_cast<std::size_t>(y) * base_stride);
      for (std::uint32_t x = 0; x < width; ++x)
        for (unsigned c = 0; c < 3; ++c) base.at(x, y, c) = srgb_eotf(row[x * 3 + c] / base_max);
    } else {
      const auto* row = base_plane + static_cast<std::size_t>(y) * base_stride;
      for (std::uint32_t x = 0; x < width; ++x)
        for (unsigned c = 0; c < 3; ++c) base.at(x, y, c) = srgb_eotf(row[x * 3 + c] / base_max);
    }
  }
  for (std::uint32_t y = 0; y < gain_height; ++y) {
    if (gain_bits <= 8) {
      for (std::uint32_t x = 0; x < gain_width; ++x) gain.at(x, y, 0) = gain_plane[static_cast<std::size_t>(y) * gain_stride + x] / gain_max;
    } else {
      const auto* row = reinterpret_cast<const std::uint16_t*>(gain_plane + static_cast<std::size_t>(y) * gain_stride);
      for (std::uint32_t x = 0; x < gain_width; ++x) gain.at(x, y, 0) = row[x] / gain_max;
    }
  }
  const float stops = static_cast<float>(metadata.alternate_headroom.numerator) /
                      static_cast<float>(metadata.alternate_headroom.denominator);
  const auto hdr = reconstruct_gain_map(base, gain, metadata, stops);

  auto le16 = [](std::vector<std::uint8_t>& out, std::uint16_t v) {
    out.push_back(static_cast<std::uint8_t>(v)); out.push_back(static_cast<std::uint8_t>(v >> 8));
  };
  auto le32 = [](std::vector<std::uint8_t>& out, std::uint32_t v) {
    out.push_back(static_cast<std::uint8_t>(v)); out.push_back(static_cast<std::uint8_t>(v >> 8));
    out.push_back(static_cast<std::uint8_t>(v >> 16)); out.push_back(static_cast<std::uint8_t>(v >> 24));
  };
  const auto linear_icc = display_p3_profile(true);
  constexpr std::uint16_t entry_count = 12;
  const std::uint32_t ifd_end = 8 + 2 + entry_count * 12 + 4;
  const std::uint32_t bits_offset = ifd_end;
  const std::uint32_t sample_format_offset = bits_offset + 6;
  const std::uint32_t icc_offset = sample_format_offset + 6;
  const std::uint32_t pixels_offset =
      icc_offset + static_cast<std::uint32_t>(linear_icc.size()) +
      static_cast<std::uint32_t>(linear_icc.size() & 1U);
  const std::uint64_t byte_count64 =
      static_cast<std::uint64_t>(width) * height * 3U * sizeof(float);
  if (byte_count64 > std::numeric_limits<std::uint32_t>::max()) {
    throw std::runtime_error("reconstructed TIFF exceeds classic TIFF limits");
  }
  const auto byte_count = static_cast<std::uint32_t>(byte_count64);

  std::vector<std::uint8_t> tiff{'I', 'I'};
  tiff.reserve(static_cast<std::size_t>(pixels_offset) + byte_count);
  le16(tiff, 42); le32(tiff, 8);
  le16(tiff, entry_count);
  auto entry = [&](std::uint16_t tag, std::uint16_t type, std::uint32_t count, std::uint32_t value) {
    le16(tiff, tag); le16(tiff, type); le32(tiff, count); le32(tiff, value);
  };
  entry(256, 4, 1, width);
  entry(257, 4, 1, height);
  entry(258, 3, 3, bits_offset);
  entry(259, 3, 1, 1);
  entry(262, 3, 1, 2);
  entry(273, 4, 1, pixels_offset);
  entry(277, 3, 1, 3);
  entry(278, 4, 1, height);
  entry(279, 4, 1, byte_count);
  entry(284, 3, 1, 1);
  entry(339, 3, 3, sample_format_offset);
  entry(34675, 7, static_cast<std::uint32_t>(linear_icc.size()), icc_offset);
  le32(tiff, 0);
  le16(tiff, 32); le16(tiff, 32); le16(tiff, 32);
  le16(tiff, 3); le16(tiff, 3); le16(tiff, 3);
  tiff.insert(tiff.end(), linear_icc.begin(), linear_icc.end());
  if (tiff.size() & 1U) tiff.push_back(0);
  for (const float value : hdr.pixels) {
    const float finite = std::isfinite(value) ? std::max(0.0F, value) : 0.0F;
    le32(tiff, std::bit_cast<std::uint32_t>(finite));
  }
  write_binary_file_atomic(output, tiff, true);
}
}  // namespace hyperdr
