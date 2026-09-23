#include "hyperdr/look/dcp_render.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/image/orientation.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/look/analysis.hpp"
#include "hyperdr/look/grid.hpp"
#include "hyperdr/codec/input_format.hpp"
#include "internal/budget.hpp"
#include "internal/decode_bytes.hpp"
#include "internal/cicp.hpp"
#include "internal/metadata.hpp"
#include "internal/raw.hpp"
#include "hyperdr/image/resample.hpp"
#include "hyperdr/image/transfer.hpp"

#include <libheif/heif.h>
#include <libheif/heif_aux_images.h>
#include <libheif/heif_properties.h>
#include <jpeglib.h>
#include <lcms2.h>
#include <png.h>

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <csetjmp>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace hyperdr {

namespace codec {
std::optional<DecodedImage> decode_apple_legacy_heic(
    heif_context* context, const heif_image_handle* primary,
    ColorGamut default_gamut);
}

namespace {

using codec::decode_raw;
using codec::apply_exif;
using codec::interleaved_rgb_to_linear_p3;
using codec::normalize_orientation;
using codec::keeps_preview_detail;
using codec::preview_decode_floor;
using codec::raster_budget_ok;
using codec::transfer_headroom;
using codec::SourceColor;

void check_raster_budget(std::uint32_t width, std::uint32_t height) {
  if (!raster_budget_ok(width, height)) {
    throw std::runtime_error("decoded raster exceeds the pixel or memory budget");
  }
}

struct FreeDeleter {
  void operator()(void* p) const { std::free(p); }
};
using MallocBytes = std::unique_ptr<unsigned char, FreeDeleter>;

// --- Colour management -----------------------------------------------------
//
// The transfer functions, the primaries matrices and the ICC path all live in
// internal/cicp.hpp, which the AVIF decoder shares. Only the bookkeeping around
// them is here.

DecodedImage from_interleaved_rgb(const std::uint8_t* pixels,
                                  std::uint32_t width, std::uint32_t height,
                                  std::size_t stride, int bits,
                                  const SourceColor& color = {},
                                  std::uint32_t out_width = 0,
                                  std::uint32_t out_height = 0,
                                  codec::RgbAlpha alpha = codec::RgbAlpha::None,
                                  bool composite_alpha = true) {
  DecodedImage result;
  result.linear_p3 =
      interleaved_rgb_to_linear_p3(pixels, width, height, stride, bits, color,
                                  out_width, out_height, alpha, composite_alpha);
  result.decode.sensor_width = width;
  result.decode.sensor_height = height;
  result.decode.target_width = width;
  result.decode.target_height = height;
  result.decode.decoded_width = result.linear_p3.width;
  result.decode.decoded_height = result.linear_p3.height;
  result.metadata.orientation = 1;
  return result;
}

// --- JPEG ------------------------------------------------------------------

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

struct JpegDecodeOutput {
  unsigned char* rgb{};
  std::size_t rgb_size{};
  unsigned char* icc{};
  unsigned int icc_size{};
  unsigned char* exif{};
  unsigned int exif_size{};
  unsigned int width{};
  unsigned int height{};
  unsigned int source_width{};
  unsigned int source_height{};
  // The reduction libjpeg actually applied, as num/denom. 8/8 means the image
  // was decoded at full size.
  unsigned int scale_num{8};
  unsigned int scale_denom{8};
  // Whether the *budget* forced that reduction, as opposed to a preview caller
  // asking for one. Only the first is a degradation: a preview that asked to be
  // bounded got exactly what it asked for, and reporting it as a lost-resolution
  // decode would make strict exports refuse ordinary files and make the panel
  // show a degradation banner on every frame.
  bool budget_limited{false};
  char message[JMSG_LENGTH_MAX]{};
};

void set_message(char* target, std::size_t size, const char* text) {
  std::snprintf(target, size, "%s", text);
}

// A deliberately C-style boundary. libjpeg reports a fatal error by longjmping
// out of jpeg_read_scanlines back to this frame, and the standard only defines
// that jump when nothing it unwinds past would need a destructor run. The old
// code jumped straight over a live `std::vector<std::uint8_t>`, which is
// undefined and in practice leaked width x height x 3 bytes for every corrupt
// scan -- a batch of damaged JPEGs accumulated them. Everything owned here is
// malloc'd and freed explicitly on both paths; the C++ caller adopts the
// buffers only after the jump can no longer happen.
//
// Returns 0 on success. On failure `message` is populated and every buffer is
// released.
int jpeg_decode_rgb(const unsigned char* data, std::size_t size,
                    std::uint32_t preview_max_edge, JpegDecodeOutput* out) {
  jpeg_decompress_struct info{};
  JpegError error{};
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    set_message(out->message, sizeof(out->message), error.message);
    jpeg_destroy_decompress(&info);
    std::free(out->rgb);
    std::free(out->icc);
    std::free(out->exif);
    out->rgb = nullptr;
    out->rgb_size = 0;
    out->icc = nullptr;
    out->icc_size = 0;
    out->exif = nullptr;
    out->exif_size = 0;
    return 1;
  }
  jpeg_create_decompress(&info);
  jpeg_mem_src(&info, data, static_cast<unsigned long>(size));
  jpeg_save_markers(&info, JPEG_APP0 + 1, 0xFFFF);  // Exif
  jpeg_save_markers(&info, JPEG_APP0 + 2, 0xFFFF);  // ICC
  jpeg_read_header(&info, TRUE);
  out->source_width = info.image_width;
  out->source_height = info.image_height;
  info.out_color_space = JCS_RGB;
  // A 50MP camera raw conversion or a 108MP phone shot overruns the raster
  // budget at full size, and rejecting it outright is the wrong answer: the
  // DCT gives us a cheap, exact power-of-two reduction for free. Ask libjpeg
  // for the largest 1/1, 1/2, 1/4, 1/8 scale that fits, which also shrinks the
  // decode itself -- at 1/8 libjpeg never materialises the full-size rows.
  unsigned budget_num = 0;
  for (const unsigned num : {8U, 4U, 2U, 1U}) {
    info.scale_num = num;
    info.scale_denom = 8;
    jpeg_calc_output_dimensions(&info);
    if (raster_budget_ok(info.output_width, info.output_height)) {
      budget_num = num;
      break;
    }
  }
  if (budget_num == 0) {
    set_message(out->message, sizeof(out->message),
                "image exceeds the pixel or memory budget even at 1/8 scale");
    jpeg_destroy_decompress(&info);
    return 1;
  }
  // A preview caller takes the *smallest* scale that still clears the floor,
  // never one the budget would not already have allowed. Ascending, so the
  // first match is the cheapest decode that keeps enough detail.
  unsigned chosen_num = budget_num;
  const auto floor = preview_decode_floor(preview_max_edge);
  if (floor != 0) {
    for (const unsigned num : {1U, 2U, 4U, 8U}) {
      if (num > budget_num) break;
      info.scale_num = num;
      info.scale_denom = 8;
      jpeg_calc_output_dimensions(&info);
      if (keeps_preview_detail(info.output_width, info.output_height, floor)) {
        chosen_num = num;
        break;
      }
    }
  }
  info.scale_num = chosen_num;
  info.scale_denom = 8;
  jpeg_calc_output_dimensions(&info);
  out->scale_num = chosen_num;
  out->scale_denom = 8;
  out->budget_limited = budget_num != 8;
  jpeg_start_decompress(&info);

  const std::size_t stride = static_cast<std::size_t>(info.output_width) * 3;
  out->rgb_size = stride * info.output_height;
  out->rgb = static_cast<unsigned char*>(std::malloc(out->rgb_size));
  if (out->rgb == nullptr) {
    set_message(out->message, sizeof(out->message), "out of memory");
    out->rgb_size = 0;
    jpeg_destroy_decompress(&info);
    return 1;
  }
  while (info.output_scanline < info.output_height) {
    JSAMPROW row = out->rgb + static_cast<std::size_t>(info.output_scanline) * stride;
    jpeg_read_scanlines(&info, &row, 1);
  }
  out->width = info.output_width;
  out->height = info.output_height;

  JOCTET* icc = nullptr;
  unsigned int icc_size = 0;
  if (jpeg_read_icc_profile(&info, &icc, &icc_size) && icc != nullptr &&
      icc_size != 0) {
    out->icc = icc;
    out->icc_size = icc_size;
  } else {
    std::free(icc);
  }

  for (jpeg_saved_marker_ptr marker = info.marker_list; marker != nullptr;
       marker = marker->next) {
    if (marker->marker != JPEG_APP0 + 1 || marker->data_length <= 6) continue;
    if (std::memcmp(marker->data, "Exif\0\0", 6) != 0) continue;
    const unsigned int payload = marker->data_length - 6;
    auto* copy = static_cast<unsigned char*>(std::malloc(payload));
    if (copy != nullptr) {
      std::memcpy(copy, marker->data + 6, payload);
      out->exif = copy;
      out->exif_size = payload;
    }
    break;
  }

  jpeg_finish_decompress(&info);
  jpeg_destroy_decompress(&info);
  return 0;
}

DecodedImage decode_jpeg(const std::vector<std::uint8_t>& bytes,
                         std::uint32_t preview_max_edge,
                         ColorGamut default_gamut) {
  JpegDecodeOutput output{};
  const int failed =
      jpeg_decode_rgb(bytes.data(), bytes.size(), preview_max_edge, &output);
  // Ownership transfers here, once the setjmp/longjmp region is behind us.
  const MallocBytes rgb(output.rgb);
  const MallocBytes icc(output.icc);
  const MallocBytes exif(output.exif);
  if (failed != 0) {
    throw std::runtime_error(std::string("JPEG decode: ") + output.message);
  }

  SourceColor color(default_gamut);
  if (output.icc_size != 0) {
    color.icc.assign(icc.get(), icc.get() + output.icc_size);
  }
  auto result = from_interleaved_rgb(
      rgb.get(), output.width, output.height,
      static_cast<std::size_t>(output.width) * 3, 8, color);
  // Preserve file geometry before orientation normalizes target and delivered
  // dimensions. DCT scaling changes only delivered size; sensor stays stored.
  result.decode.sensor_width = result.decode.target_width = output.source_width;
  result.decode.sensor_height = result.decode.target_height = output.source_height;
  result.decode.resolution_reduced = output.budget_limited;

  // Carry the portable photographic fields forward before normalising
  // orientation. The old path kept only Orientation and silently replaced
  // camera, lens, exposure, authorship and GPS with an almost-empty Exif block.
  if (output.exif_size != 0) {
    const auto read = read_exif(exif.get(), output.exif_size);
    apply_exif(result, read);
    if (read.orientation) normalize_orientation(result, *read.orientation);
  }
  return result;
}

// --- PNG -------------------------------------------------------------------

struct PngReadState {
  const unsigned char* data{};
  std::size_t size{};
  std::size_t offset{};
};

void png_read_from_memory(png_structp png, png_bytep target, png_size_t length) {
  auto* state = static_cast<PngReadState*>(png_get_io_ptr(png));
  if (state == nullptr || length > state->size - state->offset) {
    png_error(png, "read past the end of the PNG");
    return;
  }
  std::memcpy(target, state->data + state->offset, length);
  state->offset += length;
}

void png_warn(png_structp, png_const_charp) {}

struct PngReader {
  png_structp png{png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, png_warn)};
  png_infop info{};
  PngReadState input;

  explicit PngReader(const std::vector<std::uint8_t>& bytes)
      : input{bytes.data(), bytes.size(), 0} {
    if (!png) throw std::runtime_error("cannot create a PNG reader");
    info = png_create_info_struct(png);
    if (!info) {
      png_destroy_read_struct(&png, nullptr, nullptr);
      throw std::runtime_error("cannot create PNG info");
    }
    png_set_read_fn(png, &input, png_read_from_memory);
  }
  ~PngReader() { png_destroy_read_struct(&png, &info, nullptr); }
};

// Each operation below calls only libpng and has no C++ owners in its frame.
// A libpng error jumps back here, then throws normally through the caller's
// RAII objects. In particular, row colour conversion runs outside this frame.
template <typename Read>
void checked_png_read(png_structp png, const Read& read) {
  if (setjmp(png_jmpbuf(png))) throw std::runtime_error("PNG decode failed");
  read();
}

SourceColor png_source_color(png_structp png, png_infop info, ColorGamut fallback,
                             bool& narrow_range) {
  SourceColor color(fallback);
  png_byte primaries = 0, transfer = 0, matrix = 0, full_range = 1;
  bool has_cicp = false;
#ifdef PNG_READ_cICP_SUPPORTED
  has_cicp = png_get_cICP(png, info, &primaries, &transfer, &matrix, &full_range) != 0;
#else
  // Older libpng keeps this ancillary chunk opaque but still validates its CRC.
  png_unknown_chunkp chunks = nullptr;
  const int count = png_get_unknown_chunks(png, info, &chunks);
  for (int i = 0; i < count; ++i) {
    if (std::memcmp(chunks[i].name, "cICP", 4) == 0 && chunks[i].size == 4) {
      primaries = chunks[i].data[0];
      transfer = chunks[i].data[1];
      matrix = chunks[i].data[2];
      full_range = chunks[i].data[3];
      has_cicp = true;
      break;
    }
  }
#endif
  // PNG 3 specifies cICP > iCCP > sRGB > cHRM/gAMA. Do not send a
  // lower-priority ICC profile to the shared ICC-first raster converter.
  if (has_cicp) {
    if (matrix != 0 || full_range > 1)
      throw std::runtime_error("PNG cICP requires RGB samples and a valid range flag");
    narrow_range = full_range == 0;
    if (!codec::cicp_primaries_unspecified(primaries)) color.primaries = primaries;
    if (transfer != codec::kCicpTransferReserved && transfer != codec::kCicpTransferUnspecified)
      color.transfer = transfer;
    return color;
  }
  char* profile_name = nullptr;
  int compression = 0;
  png_bytep profile = nullptr;
  png_uint_32 profile_size = 0;
  if (png_get_iCCP(png, info, &profile_name, &compression, &profile, &profile_size)) {
    color.icc.assign(profile, profile + profile_size);
    return color;
  }
  int intent = 0;
  if (png_get_sRGB(png, info, &intent)) return SourceColor(ColorGamut::kSrgb);

  double gamma = 0;
  const bool has_gamma = png_get_gAMA(png, info, &gamma) != 0;
  cmsCIExyY white{.3127, .3290, 1};
  cmsCIExyYTRIPLE chromaticities{{.640, .330, 1}, {.300, .600, 1}, {.150, .060, 1}};
  if (fallback == ColorGamut::kDisplayP3)
    chromaticities = {{.680, .320, 1}, {.265, .690, 1}, {.150, .060, 1}};
  else if (fallback == ColorGamut::kRec2020)
    chromaticities = {{.708, .292, 1}, {.170, .797, 1}, {.131, .046, 1}};
  const bool has_chrm = png_get_cHRM(png, info, &white.x, &white.y,
      &chromaticities.Red.x, &chromaticities.Red.y,
      &chromaticities.Green.x, &chromaticities.Green.y,
      &chromaticities.Blue.x, &chromaticities.Blue.y) != 0;
  if (!has_gamma && !has_chrm) return color;

  // gAMA is the encoding exponent. Little CMS expects the inverse decoding
  // curve. With cHRM alone retain the documented sRGB transfer assumption.
  const codec::ProfileHandle srgb(cmsCreate_sRGBProfile());
  if (!srgb) throw std::runtime_error("cannot build the PNG transfer profile");
  cmsToneCurve* curve = has_gamma ? cmsBuildGamma(nullptr, 1.0 / gamma)
      : cmsDupToneCurve(static_cast<cmsToneCurve*>(cmsReadTag(srgb.get(), cmsSigRedTRCTag)));
  if (!curve) throw std::runtime_error("cannot build the PNG tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  const codec::ProfileHandle generated(cmsCreateRGBProfile(&white, &chromaticities, curves));
  cmsFreeToneCurve(curve);
  if (!generated) throw std::runtime_error("cannot build the PNG colour profile");
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(generated.get(), nullptr, &size))
    throw std::runtime_error("cannot serialize the PNG colour profile");
  color.icc.resize(size);
  if (!cmsSaveProfileToMem(generated.get(), color.icc.data(), &size))
    throw std::runtime_error("cannot serialize the PNG colour profile");
  return color;
}

DecodedImage decode_png(const std::vector<std::uint8_t>& bytes,
                        std::uint32_t preview_max_edge,
                        ColorGamut default_gamut) {
  PngReader reader(bytes);
  auto* png = reader.png;
  auto* info = reader.info;
  png_uint_32 width = 0, height = 0;
  int bit_depth = 0, color_type = 0, interlace = 0;
  checked_png_read(png, [&] {
#ifndef PNG_READ_cICP_SUPPORTED
    const png_byte cicp_name[5]{'c', 'I', 'C', 'P', 0};
    png_set_keep_unknown_chunks(png, PNG_HANDLE_CHUNK_ALWAYS, cicp_name, 1);
#endif
    png_read_info(png, info);
    png_get_IHDR(png, info, &width, &height, &bit_depth, &color_type, &interlace, nullptr, nullptr);
    if (color_type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
    if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (png_get_valid(png, info, PNG_INFO_tRNS)) png_set_tRNS_to_alpha(png);
    if (!(color_type & PNG_COLOR_MASK_COLOR)) png_set_gray_to_rgb(png);
    if (bit_depth == 16) png_set_swap(png);
    png_set_interlace_handling(png);
    png_read_update_info(png, info);
  });
  const int bits = bit_depth == 16 ? 16 : 8;
  const auto channels = png_get_channels(png, info);
  const std::size_t row_bytes = png_get_rowbytes(png, info);
  if ((channels != 3 && channels != 4) ||
      row_bytes != static_cast<std::size_t>(width) * channels * (bits / 8))
    throw std::runtime_error("unsupported PNG channel layout");
  bool narrow_range = false;
  const auto color = png_source_color(png, info, default_gamut, narrow_range);
  const codec::RgbRowTransform transform(color, bits, narrow_range, true,
      channels == 4 ? codec::RgbAlpha::Straight : codec::RgbAlpha::None);

  const auto plan = codec::raster_decode_plan(width, height, preview_max_edge);
  const auto out_width = plan.width;
  const auto out_height = plan.height;
  const bool reduce = out_width != width || out_height != height;
  std::vector<unsigned char> raster;
  if (interlace != PNG_INTERLACE_NONE) {
    // Adam7 needs the full encoded raster to combine its passes. Feed those
    // completed rows through the same linear reduction as ordinary PNG rows.
    check_raster_budget(width, height);
    raster.resize(row_bytes * height);
    std::vector<png_bytep> rows(height);
    for (unsigned y = 0; y < height; ++y) rows[y] = raster.data() + y * row_bytes;
    checked_png_read(png, [&] { png_read_image(png, rows.data()); });
  }
  FloatImage linear(out_width, out_height, 3);
  // Bound scratch memory by 64 source rows, while allowing the shared pool to
  // perform expensive ICC transforms concurrently. PNG inflation stays serial.
  constexpr std::uint32_t kBlockRows = 64;
  const auto block_rows = std::min(height, kBlockRows);
  std::vector<unsigned char> encoded(raster.empty() ? row_bytes * block_rows : 0);
  const std::size_t source_stride = static_cast<std::size_t>(width) * 3;
  const std::size_t output_stride = static_cast<std::size_t>(out_width) * 3;
  std::vector<float> source(reduce ? source_stride * block_rows : 0);
  std::vector<float> horizontal(reduce ? output_stride * block_rows : 0);
  std::uint32_t first_row = height;
  const auto load_block = [&](std::uint32_t y) {
    first_row = (y / kBlockRows) * kBlockRows;
    const auto count = std::min(kBlockRows, height - first_row);
    if (raster.empty()) {
      checked_png_read(png, [&] {
        for (unsigned row = 0; row < count; ++row)
          png_read_row(png, encoded.data() + row * row_bytes, nullptr);
      });
    }
    parallel_for_rows(count, [&](std::uint32_t row) {
      const auto* input = raster.empty() ? encoded.data() + row * row_bytes
          : raster.data() + (static_cast<std::size_t>(first_row) + row) * row_bytes;
      if (!reduce) {
        transform.convert(input, linear.pixels.data() +
            (static_cast<std::size_t>(first_row) + row) * output_stride, width);
        return;
      }
      auto* converted = source.data() + row * source_stride;
      auto* reduced = horizontal.data() + row * output_stride;
      transform.convert(input, converted, width);
      // Integer boundaries in units of 1/output_size avoid rounded indices.
      // Each output cell has equal area, including odd-sized source rasters.
      for (std::uint32_t ox = 0; ox < out_width; ++ox) {
        const auto left = static_cast<std::uint64_t>(ox) * width;
        const auto right = static_cast<std::uint64_t>(ox + 1) * width;
        std::array<double, 3> sum{};
        for (auto sx = left / out_width; sx <= (right - 1) / out_width; ++sx) {
          const double weight = static_cast<double>(std::min(right, (sx + 1) * out_width) -
              std::max(left, sx * out_width)) / width;
          for (unsigned c = 0; c < 3; ++c) sum[c] += converted[sx * 3 + c] * weight;
        }
        for (unsigned c = 0; c < 3; ++c) reduced[static_cast<std::size_t>(ox) * 3 + c] = static_cast<float>(sum[c]);
      }
    });
  };
  if (!reduce) {
    for (std::uint32_t y = 0; y < height; y += kBlockRows) load_block(y);
  } else {
    for (std::uint32_t oy = 0; oy < out_height; ++oy) {
      const auto top = static_cast<std::uint64_t>(oy) * height;
      const auto bottom = static_cast<std::uint64_t>(oy + 1) * height;
      auto* target = linear.pixels.data() + static_cast<std::size_t>(oy) * output_stride;
      for (auto sy = top / out_height; sy <= (bottom - 1) / out_height; ++sy) {
        if (sy < first_row || sy >= static_cast<std::uint64_t>(first_row) + kBlockRows)
          load_block(static_cast<std::uint32_t>(sy));
        const auto* reduced = horizontal.data() + (sy - first_row) * output_stride;
        const float weight = static_cast<float>(static_cast<double>(std::min(bottom, (sy + 1) * out_height) -
            std::max(top, sy * out_height)) / height);
        for (std::size_t i = 0; i < output_stride; ++i) target[i] += reduced[i] * weight;
      }
    }
  }
  checked_png_read(png, [&] { png_read_end(png, info); });
  DecodedImage result;
  result.linear_p3 = std::move(linear);
  result.decode.sensor_width = result.decode.target_width = width;
  result.decode.sensor_height = result.decode.target_height = height;
  result.decode.decoded_width = out_width;
  result.decode.decoded_height = out_height;
  result.metadata.orientation = 1;
  result.decode.resolution_reduced = plan.budget_limited;
  result.hdr_headroom = color.icc.empty() ? transfer_headroom(color.transfer) : 1.0F;
#ifdef PNG_cLLI_SUPPORTED
  png_uint_32 max_cll = 0, max_fall = 0;
  if (result.hdr_headroom > 1.0F && png_get_cLLI_fixed(png, info, &max_cll, &max_fall) && max_cll != 0)
    result.content_peak_nits = static_cast<float>(max_cll / 10000.0);
#endif
  result.domain = display_referred_domain(result.hdr_headroom);
  return result;
}

// --- HEIF ------------------------------------------------------------------

void check_heif(const heif_error& error, const char* operation) {
  if (error.code != heif_error_Ok) {
    throw std::runtime_error(std::string(operation) + ": " +
                             (error.message ? error.message : "unknown libheif error"));
  }
}

struct ContextDeleter { void operator()(heif_context* p) const { heif_context_free(p); } };
struct HandleDeleter { void operator()(heif_image_handle* p) const { heif_image_handle_release(p); } };
struct ImageDeleter { void operator()(heif_image* p) const { heif_image_release(p); } };
struct DecodingOptionsDeleter {
  void operator()(heif_decoding_options* p) const {
    if (p) heif_decoding_options_free(p);
  }
};

std::optional<ExifRead> read_heif_exif(
    const heif_image_handle* handle,
    std::optional<float>* apple_headroom = nullptr) {
  const int count =
      heif_image_handle_get_number_of_metadata_blocks(handle, "Exif");
  if (count <= 0 || count > 64) return std::nullopt;
  std::vector<heif_item_id> ids(static_cast<std::size_t>(count));
  const int written = heif_image_handle_get_list_of_metadata_block_IDs(
      handle, "Exif", ids.data(), count);
  if (written <= 0) return std::nullopt;
  constexpr std::size_t kMaximumExifBytes = 16U << 20U;
  for (int index = 0; index < written; ++index) {
    const std::size_t size =
        heif_image_handle_get_metadata_size(handle, ids[index]);
    if (size == 0 || size > kMaximumExifBytes) continue;
    std::vector<std::uint8_t> bytes(size);
    if (heif_image_handle_get_metadata(handle, ids[index], bytes.data()).code !=
        heif_error_Ok) {
      continue;
    }
    if (apple_headroom)
      *apple_headroom = read_apple_legacy_gain_headroom(bytes.data(), bytes.size());
    // Orientation parsing is intentionally independent of the broader photo
    // metadata parser: one malformed optional Exif field must not prevent a
    // valid IFD0 Orientation tag from being normalised.
    return read_exif(bytes.data(), bytes.size());
  }
  return std::nullopt;
}

bool has_heif_orientation_transform(const heif_context* context,
                                    const heif_image_handle* handle) {
  const auto id = heif_image_handle_get_item_id(handle);
  return heif_item_get_properties_of_type(
             context, id, heif_item_property_type_transform_rotation,
             nullptr, 0) > 0 ||
         heif_item_get_properties_of_type(
             context, id, heif_item_property_type_transform_mirror,
             nullptr, 0) > 0;
}

DecodedImage decode_heif_rgb_handle(const heif_context* context,
                                    const heif_image_handle* handle,
                                    std::uint32_t preview_max_edge,
                                    ColorGamut default_gamut,
                                    bool normalize_exif = true,
                                    std::uint16_t* exif_orientation = nullptr,
                                    FloatImage* alpha_out = nullptr) {
  SourceColor color(default_gamut);
  // Keep the project-wide ICC-first policy. ICC is the only profile form here
  // that can describe arbitrary RGB primaries; nclx is the fallback for files
  // that do not carry a usable ICC profile.
  const auto profile_type = heif_image_handle_get_color_profile_type(handle);
  if (profile_type == heif_color_profile_type_prof ||
      profile_type == heif_color_profile_type_rICC) {
    const std::size_t size = heif_image_handle_get_raw_color_profile_size(handle);
    if (size != 0 && size <= (4U << 20U)) {
      color.icc.resize(size);
      if (heif_image_handle_get_raw_color_profile(handle, color.icc.data()).code !=
          heif_error_Ok) {
        color.icc.clear();
      }
    }
  }
  {
    heif_color_profile_nclx* profile_raw = nullptr;
    const auto profile_error =
        heif_image_handle_get_nclx_color_profile(handle, &profile_raw);
    const bool has_nclx = profile_error.code == heif_error_Ok && profile_raw != nullptr;
    if (has_nclx) {
      const int transfer = profile_raw->transfer_characteristics;
      if (color.icc.empty() || transfer == codec::kCicpTransferPq ||
          transfer == codec::kCicpTransferHlg) {
        if (transfer == codec::kCicpTransferPq || transfer == codec::kCicpTransferHlg)
          color.icc.clear();
        color.primaries = profile_raw->color_primaries;
        color.transfer = transfer;
        if (codec::cicp_primaries_unspecified(color.primaries)) {
          color.primaries = codec::cicp_primaries_for_gamut(default_gamut);
        }
      }
    }
    if (profile_raw != nullptr) heif_nclx_color_profile_free(profile_raw);
  }

  const bool wide = heif_image_handle_get_luma_bits_per_pixel(handle) > 8;
  const bool has_alpha = heif_image_handle_has_alpha_channel(handle) != 0;
  const auto alpha = !has_alpha ? codec::RgbAlpha::None
      : heif_image_handle_is_premultiplied_alpha(handle) ? codec::RgbAlpha::Premultiplied
                                                       : codec::RgbAlpha::Straight;
  std::unique_ptr<heif_decoding_options, DecodingOptionsDeleter> options(
      heif_decoding_options_alloc());
  if (!options) throw std::runtime_error("cannot allocate HEIC decoding options");
  // The libheif default converts to sRGB and can silently discard BT.2100 HDR.
  // Preserve the source CICP so transfer decoding below is the exact inverse of
  // this project's PQ/HLG encoder.
  options->output_image_nclx_profile_passthrough = 1;
  options->convert_hdr_to_8bit = 0;

  heif_image* image_raw = nullptr;
  check_heif(heif_decode_image(handle, &image_raw, heif_colorspace_RGB,
                               wide ? (has_alpha ? heif_chroma_interleaved_RRGGBBAA_LE : heif_chroma_interleaved_RRGGBB_LE)
                                    : (has_alpha ? heif_chroma_interleaved_RGBA : heif_chroma_interleaved_RGB),
                               options.get()),
             "HEIC decode");
  std::unique_ptr<heif_image, ImageDeleter> image(image_raw);
  const int full_width = heif_image_get_width(image.get(), heif_channel_interleaved);
  const int full_height = heif_image_get_height(image.get(), heif_channel_interleaved);
  if (full_width <= 0 || full_height <= 0)
    throw std::runtime_error("HEIC decoder returned invalid dimensions");
  // Adaptive HDR must reconstruct before compositing. Independently reducing
  // unassociated colour and alpha would change their product at image edges.
  if (alpha_out && has_alpha) check_raster_budget(full_width, full_height);
  const auto plan = codec::raster_decode_plan(static_cast<std::uint32_t>(full_width),
      static_cast<std::uint32_t>(full_height), preview_max_edge);
  int stride = 0;
  const auto* rgb =
      heif_image_get_plane_readonly(image.get(), heif_channel_interleaved, &stride);
  const int width = heif_image_get_width(image.get(), heif_channel_interleaved);
  const int height = heif_image_get_height(image.get(), heif_channel_interleaved);
  const int bits = heif_image_get_bits_per_pixel_range(image.get(),
                                                       heif_channel_interleaved);
  if (!rgb || stride <= 0 || width <= 0 || height <= 0 || bits <= 0 || bits > 16) {
    throw std::runtime_error("HEIC decoder returned an invalid RGB plane");
  }
  auto result = from_interleaved_rgb(
      rgb, static_cast<std::uint32_t>(width),
      static_cast<std::uint32_t>(height),
      static_cast<std::size_t>(stride), bits, color, plan.width, plan.height,
      alpha, alpha_out == nullptr);
  if (alpha_out && has_alpha) {
    *alpha_out = FloatImage(width, height, 1);
    const float maximum = static_cast<float>((1U << bits) - 1U);
    for (int y = 0; y < height; ++y) for (int x = 0; x < width; ++x) {
      const auto* sample = rgb + static_cast<std::size_t>(y) * stride +
          (static_cast<std::size_t>(x) * 4 + 3) * (bits > 8 ? 2 : 1);
      const unsigned value = bits > 8 ? sample[0] | (static_cast<unsigned>(sample[1]) << 8) : sample[0];
      alpha_out->at(x, y, 0) = value / maximum;
    }
  }
  result.decode.sensor_width = heif_image_handle_get_ispe_width(handle);
  result.decode.sensor_height = heif_image_handle_get_ispe_height(handle);
  result.decode.target_width = full_width;
  result.decode.target_height = full_height;
  result.decode.resolution_reduced = plan.budget_limited;
  // An ICC-only file has no declared HDR transfer. PQ/HLG nclx remains
  // authoritative for transfer and range when both profiles are present.
  result.hdr_headroom = transfer_headroom(color.transfer);
  heif_content_light_level light{};
  if (result.hdr_headroom > 1.0F && heif_image_handle_get_content_light_level(handle, &light) &&
      light.max_content_light_level != 0)
    result.content_peak_nits = static_cast<float>(light.max_content_light_level);
  result.domain = display_referred_domain(result.hdr_headroom);
  ExifRead exif;
  if (auto read = read_heif_exif(handle)) exif = std::move(*read);
  apply_exif(result, exif);
  // libheif applies irot/imir properties, but it does not apply an independent
  // Exif Orientation tag. Prefer the container transform when both exist so a
  // producer that duplicated the orientation cannot rotate the image twice.
  const auto orientation = has_heif_orientation_transform(context, handle)
                               ? std::uint16_t{1}
                               : exif.orientation.value_or(1);
  if (exif_orientation != nullptr) *exif_orientation = orientation;
  if (normalize_exif) normalize_orientation(result, orientation);
  return result;
}

DecodedImage decode_adaptive_heic(const std::vector<std::uint8_t>& bytes,
                                heif_context* context,
                                bool base_only,
                                ColorGamut default_gamut) {
  const auto inspection = inspect_heif(bytes);
  if (!inspection.structurally_valid || !inspection.has_tmap_brand ||
      !inspection.has_tmap_item || !inspection.has_dimg_reference) {
    throw std::runtime_error("Adaptive HDR HEIC has invalid tmap structure");
  }
  const auto references = find_tmap_references(bytes);
  const auto metadata = parse_tmap_payload(extract_tmap_payload(bytes));
  const auto gain_channels = gain_map_channel_count(metadata);

  heif_image_handle* base_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context, references.base_id, &base_handle_raw),
             "get Adaptive HDR base image");
  std::unique_ptr<heif_image_handle, HandleDeleter> base_handle(base_handle_raw);
  // Reconstruct in the stored raster coordinate system, then apply an
  // Exif-only orientation to the complete HDR result. Rotating the base before
  // sampling the gain grid would attach gain to the wrong parts of the image.
  std::uint16_t exif_orientation = 1;
  FloatImage alpha;
  // No preview reduction here: the gain grid below is rejected when it is
  // larger than the base, and every Apple gain map is a fraction of its base's
  // size, so shrinking the base would make an ordinary file look malformed.
  auto result = decode_heif_rgb_handle(context, base_handle.get(), 0,
                                       default_gamut, false,
                                       &exif_orientation, base_only ? nullptr : &alpha);
  if (base_only) {
    normalize_orientation(result, exif_orientation);
    return result;
  }

  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context, references.gain_id, &gain_handle_raw),
             "get Adaptive HDR Gain Map");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw,
                               gain_channels == 1 ? heif_colorspace_YCbCr : heif_colorspace_RGB,
                               gain_channels == 1 ? heif_chroma_420 : heif_chroma_interleaved_RGB,
                               nullptr),
             "decode Adaptive HDR Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);
  const auto gain_channel = gain_channels == 1 ? heif_channel_Y : heif_channel_interleaved;
  const int gain_width = heif_image_get_width(gain_image.get(), gain_channel);
  const int gain_height = heif_image_get_height(gain_image.get(), gain_channel);
  const int gain_bits =
      heif_image_get_bits_per_pixel_range(gain_image.get(), gain_channel);
  int gain_stride = 0;
  const auto* gain_plane =
      heif_image_get_plane_readonly(gain_image.get(), gain_channel, &gain_stride);
  if (!gain_plane || gain_width <= 0 || gain_height <= 0 || gain_stride <= 0 ||
      gain_bits < 1 || gain_bits > 16 ||
      gain_width > static_cast<int>(result.linear_p3.width) ||
      gain_height > static_cast<int>(result.linear_p3.height)) {
    throw std::runtime_error("Adaptive HDR Gain Map has invalid dimensions or depth");
  }

  FloatImage gain(static_cast<std::uint32_t>(gain_width),
                  static_cast<std::uint32_t>(gain_height),
                  static_cast<std::uint32_t>(gain_channels));
  const float gain_max = static_cast<float>((1U << gain_bits) - 1U);
  for (int y = 0; y < gain_height; ++y) {
    const auto* row = gain_plane + static_cast<std::size_t>(y) * gain_stride;
    for (int x = 0; x < gain_width; ++x) {
      for (std::size_t c = 0; c < gain_channels; ++c) {
        const auto index = (static_cast<std::size_t>(x) * gain_channels + c) *
                           (gain_bits > 8 ? 2U : 1U);
        std::uint16_t code = row[index];
        if (gain_bits > 8) {
          code = static_cast<std::uint16_t>(row[index] |
              (static_cast<std::uint16_t>(row[index + 1]) << 8));
        }
        gain.at(static_cast<std::uint32_t>(x), static_cast<std::uint32_t>(y),
                static_cast<std::uint32_t>(c)) =
            code / gain_max;
      }
    }
  }
  const float alternate_headroom =
      static_cast<float>(metadata.alternate_headroom.numerator) /
      static_cast<float>(metadata.alternate_headroom.denominator);
  result.authored_sdr = result.linear_p3;
  result.gain_map.channels = static_cast<std::uint32_t>(gain_channels);
  result.gain_map.base_headroom = std::exp2(rational_value(metadata.base_headroom));
  result.gain_map.alternate_headroom = std::exp2(alternate_headroom);
  for (unsigned c = 0; c < 3; ++c) {
    const auto channel = gain_map_channel(metadata, gain_channels == 1 ? 0 : c);
    result.gain_map.base_offset[c] = rational_value(channel.base_offset);
    result.gain_map.alternate_offset[c] = rational_value(channel.alternate_offset);
  }
  result.linear_p3 = reconstruct_gain_map(*result.authored_sdr, gain, metadata,
                                          alternate_headroom);
  if (!alpha.pixels.empty()) {
    for (std::size_t i = 0; i < alpha.pixels.size(); ++i)
      for (unsigned c = 0; c < 3; ++c) {
        auto& hdr = result.linear_p3.pixels[i * 3 + c];
        auto& sdr = result.authored_sdr->pixels[i * 3 + c];
        hdr *= alpha.pixels[i];
        sdr *= alpha.pixels[i];
      }
  }
  // The base is a Display P3 SDR image, so the headroom is entirely whatever
  // the gain map was written to add. `alternate_headroom` is in stops.
  result.hdr_headroom = std::max(1.0F, std::exp2(alternate_headroom));
  // The gain-map metadata describes the reconstructed image. A base item's
  // content-light hint, if present, cannot describe this different rendition.
  result.content_peak_nits.reset();
  // A tmap file whose gain map adds nothing is an SDR picture in an HDR
  // container, and saying so keeps it out of the highlight-splitting renderer.
  result.domain = InputDomain::kDualRendition;
  normalize_orientation(result, exif_orientation);
  return result;
}

DecodedImage decode_heic(const std::vector<std::uint8_t>& bytes, bool base_only,
                         std::uint32_t preview_max_edge,
                         ColorGamut default_gamut) {
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HEIC decoder");
  check_heif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr),
             "HEIC open");
  const auto inspection = inspect_heif(bytes);
  if (inspection.has_tmap_brand || inspection.has_tmap_item) {
    return decode_adaptive_heic(bytes, context.get(), base_only, default_gamut);
  }
  heif_image_handle* handle_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &handle_raw),
             "HEIC primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_raw);
  if (!base_only) {
    if (auto legacy = codec::decode_apple_legacy_heic(context.get(), handle.get(),
            default_gamut))
      return std::move(*legacy);
  }
  return decode_heif_rgb_handle(context.get(), handle.get(), preview_max_edge,
                                default_gamut);
}

}  // namespace

namespace codec {
DecodedImage decode_jpeg_primary_bytes(const std::vector<std::uint8_t>& bytes,
                                       ColorGamut default_gamut) {
  return decode_jpeg(bytes, 0, default_gamut);
}

std::optional<DecodedImage> decode_apple_legacy_heic(
    heif_context* context, const heif_image_handle* primary,
    ColorGamut default_gamut) {
  const int count = heif_image_handle_get_number_of_auxiliary_images(primary,
      LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA | LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH);
  if (count <= 0 || count > 64) return std::nullopt;
  std::vector<heif_item_id> ids(static_cast<std::size_t>(count));
  const int written = heif_image_handle_get_list_of_auxiliary_image_IDs(
      primary, LIBHEIF_AUX_IMAGE_FILTER_OMIT_ALPHA |
      LIBHEIF_AUX_IMAGE_FILTER_OMIT_DEPTH, ids.data(), count);
  for (int i = 0; i < written; ++i) {
    heif_image_handle* aux_raw = nullptr;
    if (heif_image_handle_get_auxiliary_image_handle(primary, ids[i], &aux_raw).code !=
        heif_error_Ok) continue;
    std::unique_ptr<heif_image_handle, HandleDeleter> aux(aux_raw);
    const char* type = nullptr;
    if (heif_image_handle_get_auxiliary_type(aux.get(), &type).code != heif_error_Ok)
      continue;
    const bool legacy = type && std::strcmp(type,
        "urn:com:apple:photo:2020:aux:hdrgainmap") == 0;
    heif_image_handle_release_auxiliary_type(aux.get(), &type);
    if (!legacy) continue;

    std::optional<float> headroom;
    if (!read_heif_exif(primary, &headroom) || !headroom || *headroom < 1.0F)
      throw std::runtime_error("Apple legacy gain map lacks usable MakerNote headroom");
    heif_image* gain_raw = nullptr;
    check_heif(heif_decode_image(aux.get(), &gain_raw, heif_colorspace_YCbCr,
                                 heif_chroma_420, nullptr),
               "decode Apple legacy gain map");
    std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);
    const int width = heif_image_get_width(gain_image.get(), heif_channel_Y);
    const int height = heif_image_get_height(gain_image.get(), heif_channel_Y);
    const int bits = heif_image_get_bits_per_pixel_range(gain_image.get(), heif_channel_Y);
    int stride = 0;
    const auto* plane = heif_image_get_plane_readonly(gain_image.get(), heif_channel_Y, &stride);
    if (!plane || width <= 0 || height <= 0 || bits != 8 || stride < width)
      throw std::runtime_error("Apple legacy gain map has invalid pixels");

    // Decode the full base before sampling the auxiliary grid. The preview
    // caller reduces both planes together after reconstruction.
    std::uint16_t orientation = 1;
    auto result = decode_heif_rgb_handle(context, primary, 0, default_gamut,
                                         false, &orientation, nullptr);
    FloatImage encoded(width, height, 1);
    for (int y = 0; y < height; ++y)
      for (int x = 0; x < width; ++x)
        encoded.at(x, y, 0) = plane[static_cast<std::size_t>(y) * stride + x] / 255.0F;
    result.authored_sdr = result.linear_p3;
    result.gain_map.channels = 1;
    result.gain_map.base_headroom = 1.0F;
    result.gain_map.alternate_headroom = *headroom;
    const BilinearGridSampler sampler(encoded.width, encoded.height,
                                      result.linear_p3.width, result.linear_p3.height);
    const GridView grid(encoded.pixels, encoded.width, encoded.height);
    parallel_for_rows(result.linear_p3.height, [&](std::uint32_t y) {
      for (std::uint32_t x = 0; x < result.linear_p3.width; ++x) {
        const float gain = bt709_inverse_oetf(sampler.sample(grid, x, y));
        const float multiplier = 1.0F + (*headroom - 1.0F) * gain;
        for (unsigned c = 0; c < 3; ++c)
          result.linear_p3.at(x, y, c) *= multiplier;
      }
    });
    result.hdr_headroom = *headroom;
    result.content_peak_nits.reset();
    result.domain = InputDomain::kDualRendition;
    normalize_orientation(result, orientation);
    return result;
  }
  return std::nullopt;
}
}  // namespace codec

DecodedImage decode_image(const std::filesystem::path& path, const RawDecodeOptions& options) {
  const auto ext = lower_extension(path);

  // RAW stays name-decided, and has to. Most RAW containers *are* TIFF, so a
  // signature cannot tell a .dng from any other TIFF, and LibRaw's memory
  // admission works from the path rather than from a buffer we would otherwise
  // have to hold alongside the sensor data.
  if (is_raw_extension(ext)) return decode_raw(path, options);

  // Everything else is decided by its leading bytes. A phone gallery exports
  // HEIC under a .jpg name routinely, and until now that file reached the plain
  // JPEG decoder and was rejected for a bad marker -- a true statement about a
  // file that was never a JPEG. The extension has already done its job by this
  // point: it is what discovery and the panel's upload guard admit on.
  const auto head = read_binary_prefix(path, kSignaturePrefixBytes);
  const auto format = probe_input_signature(head);
  if (format == InputFormat::Unknown) {
    throw std::invalid_argument("unsupported input format: " + ext +
                                " (contents match no supported signature)");
  }

  // The one read. Every probe and decoder below works from this buffer, so a
  // JPEG is no longer opened twice -- once to ask whether it carries a gain map
  // and once to decode it.
  const auto bytes = read_binary_file(path);

  switch (format) {
    case InputFormat::Jpeg:
      // A JPEG/R carries an SDR primary plus a gain map. Reading only the
      // primary would discard the captured highlight range before any look
      // decision, so the gain map is applied first and the plain-JPEG path is
      // the fallback.
      if (!options.ignore_embedded_gain_map && codec::is_ultrahdr_bytes(bytes)) {
        try {
          return codec::decode_ultrahdr_bytes(bytes, options.default_gamut);
        } catch (const std::exception&) {
          // Keep the backward-compatible primary usable, but never pretend that
          // losing the advertised HDR rendition was an ordinary successful
          // decode.  Export/report callers already surface DecodeInfo degraded
          // state and the panel carries it in the native preview contract.
          //
          // decode_jpeg leaves the domain at display-referred SDR, which is what
          // this fallback actually produced. That is the whole reason the domain
          // is set by the decoder: the file still advertises a gain map, and a
          // name-based classifier would have handed these SDR pixels to the
          // highlight-splitting renderer.
          auto fallback = decode_jpeg(bytes, options.preview_max_edge,
                                      options.default_gamut);
          fallback.decode.degraded = true;
          fallback.decode.degradation_reasons.push_back(
              "ultrahdr_decode_failed_sdr_fallback");
          return fallback;
        }
      }
      return decode_jpeg(bytes, options.preview_max_edge, options.default_gamut);
    case InputFormat::Png:
      return decode_png(bytes, options.preview_max_edge, options.default_gamut);
    case InputFormat::Isobmff:
      // HEIF and AVIF are the same container family; the payload codec decides,
      // because libheif would otherwise reject an AV1 payload with an error
      // about the codec rather than simply reading it.
      if (codec::is_avif_bytes(bytes)) {
        return codec::decode_avif_bytes(bytes, options.preview_max_edge,
                                       options.default_gamut);
      }
      return decode_heic(bytes, options.ignore_embedded_gain_map,
                         options.preview_max_edge, options.default_gamut);
    case InputFormat::Unknown:
      break;
  }
  throw std::invalid_argument("unsupported input format: " + ext);
}

// How far above the display range this preview has to reach.
//
// A power of two, so the consumer's multiply is exact and a small change in the
// picture cannot make the preview shift brightness. The ceiling is a real
// trade-off rather than a round number: the preview is 8-bit, and dividing by
// the scale pushes diffuse white down the code range with it -- at 8, SDR white
// lands on code 71 of 255 and the shadows start to band. Eight covers the whole
// of HLG (1000/203 = 4.93) and clips only the extreme specular end of PQ, which
// is the better half of the bargain. An SDR input measures at or below 1 and
// gets a scale of 1, so its preview is byte-for-byte what it always was.
constexpr float kMaxPreviewScale = 8.0F;

// Whether to divide, and by how much.
//
// The gate is the input *format*, not the pixels. Choosing this from a
// percentile alone was wrong: a RAW decodes to values above 1.0 whenever
// white-balance normalisation leaves headroom there, so some frames in a shoot
// were scaled and others were not, and the ones that were spent a quarter of
// their preview code values on range that auto-exposure was about to bring back
// down anyway. Scene-referred and SDR inputs are therefore never scaled, and
// their previews are byte-for-byte what they always were.
//
// The magnitude still comes from the content, because a PQ file that happens to
// hold an SDR-range picture should not be darkened for headroom it does not
// use.
float preview_scale_for(const FloatImage& source, float hdr_headroom) {
  if (!(hdr_headroom > 1.0F)) return 1.0F;
  const SceneStatistics stats = compute_luminance_statistics(source);
  const float ceiling = std::min(kMaxPreviewScale, hdr_headroom);
  float scale = 1.0F;
  while (scale * 2.0F <= ceiling && stats.p9999 > scale) scale *= 2.0F;
  return scale;
}

// RAW is scene-referred, while the browser controls (and the exported SDR
// base) are display-referred. The old preview only performed the first half of
// that conversion: it decoded linear RAW values and sent them through sRGB
// without the automatic exposure that the gain-map renderer applies later.
// That made the same file look dark in the panel even though the export had
// already been lifted to the photographic middle grey. Return only the
// automatic part here; the browser's brightness slider remains the user's
// exposure bias and therefore continues to match the export.
float raw_preview_exposure_ev(const std::filesystem::path& path,
                              const FloatImage& source,
                              const CaptureMetadata& capture) {
  const auto ext = lower_extension(path);
  if (!is_raw_extension(ext)) return 0.0F;
  GainMapOptions options;
  // The panel applies the user's brightness separately. The model input and
  // the renderer therefore need the automatic anchor without that bias.
  options.exposure_bias_ev = 0.0F;
  return photographic_exposure_ev(source, options, capture);
}

PreviewJpeg encode_preview_jpeg(const std::filesystem::path& path,
                                std::uint32_t max_edge, int quality,
                                const RawDecodeOptions& options,
                                bool apply_scene_exposure) {
  if (max_edge == 0 || max_edge > 8192) {
    throw std::invalid_argument("preview max edge must be in [1,8192]");
  }
  auto decoded = decode_image(path, options);
  const bool profiled = static_cast<bool>(decoded.raw_profile);
  if (profiled) decoded.linear_p3 = render_dcp_base(decoded.linear_p3, *decoded.raw_profile);

  // Measure before resampling so the exposure anchor is not a function of the
  // requested preview size. Half-size RAW callers still intentionally trade
  // demosaic detail for speed, but the exposure algorithm is shared with the
  // formal photographic renderer.
  const float exposure_ev =
      profiled ? 0.0F : raw_preview_exposure_ev(path, decoded.linear_p3, decoded.capture);
  // Identical policy to the --preview-max-edge conversion path: repeated 2x2
  // area reduction in linear light, then one bilinear step to the exact size.
  auto source = resample_to_max_edge(std::move(decoded.linear_p3), max_edge);
  const auto width = source.width;
  const auto height = source.height;
  const float scale = preview_scale_for(source, decoded.hdr_headroom);
  const float inverse_scale = 1.0F / scale;
  const float scene_exposure = apply_scene_exposure
                                   ? std::exp2(exposure_ev)
                                   : 1.0F;

  std::vector<std::uint8_t> rgb(static_cast<std::size_t>(width) * height * 3);
  parallel_for_rows(height, [&](const std::uint32_t y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const std::array<float, 3> p3{source.at(x, y, 0), source.at(x, y, 1),
                                    source.at(x, y, 2)};
      const std::array<float, 3> srgb{
          1.22494018F * p3[0] - 0.22494018F * p3[1],
          -0.04205695F * p3[0] + 1.04205695F * p3[1],
          -0.01963755F * p3[0] - 0.07863605F * p3[1] + 1.09827360F * p3[2]};
      const auto pixel = (static_cast<std::size_t>(y) * width + x) * 3;
      for (unsigned c = 0; c < 3; ++c) {
        rgb[pixel + c] = static_cast<std::uint8_t>(std::lround(
            std::clamp(srgb_oetf(srgb[c] * scene_exposure * inverse_scale),
                       0.0F, 1.0F) * 255.0F));
      }
    }
  });

  jpeg_compress_struct info{};
  JpegError error{};
  unsigned char* output = nullptr;
  unsigned long output_size = 0;
  info.err = jpeg_std_error(&error.base);
  error.base.error_exit = jpeg_fail;
  if (setjmp(error.jump)) {
    jpeg_destroy_compress(&info);
    std::free(output);
    throw std::runtime_error(std::string("JPEG preview encode: ") + error.message);
  }
  jpeg_create_compress(&info);
  jpeg_mem_dest(&info, &output, &output_size);
  info.image_width = width;
  info.image_height = height;
  info.input_components = 3;
  info.in_color_space = JCS_RGB;
  jpeg_set_defaults(&info);
  jpeg_set_quality(&info, std::clamp(quality, 1, 100), TRUE);
  info.optimize_coding = TRUE;
  jpeg_start_compress(&info, TRUE);
  const std::size_t stride = static_cast<std::size_t>(width) * 3;
  while (info.next_scanline < info.image_height) {
    auto* row = rgb.data() + static_cast<std::size_t>(info.next_scanline) * stride;
    jpeg_write_scanlines(&info, &row, 1);
  }
  jpeg_finish_compress(&info);
  std::vector<std::uint8_t> result(output, output + output_size);
  jpeg_destroy_compress(&info);
  std::free(output);
  return {std::move(result), scale, exposure_ev};
}

}  // namespace hyperdr
