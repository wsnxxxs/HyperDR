#include "hyperdr/image/color.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/image/orientation.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "internal/budget.hpp"
#include "internal/raw.hpp"
#include "hyperdr/image/resample.hpp"
#include "hyperdr/image/transfer.hpp"

#include <libheif/heif.h>
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

namespace {

using codec::decode_raw;
using codec::raster_budget_ok;

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

// How a decoded buffer describes its own colour. An embedded ICC profile wins
// when present: it is the only description that can carry an arbitrary set of
// primaries, and JPEG and PNG in the wild use it for exactly that. The CICP
// pair is the fallback, and is what HEIF carries natively.
struct SourceColor {
  std::vector<std::uint8_t> icc;
  heif_color_primaries primaries{heif_color_primaries_ITU_R_BT_709_5};
  heif_transfer_characteristics transfer{heif_transfer_characteristic_IEC_61966_2_1};
};

struct ProfileDeleter {
  void operator()(void* p) const { cmsCloseProfile(p); }
};
struct TransformDeleter {
  void operator()(void* p) const { cmsDeleteTransform(p); }
};
using ProfileHandle = std::unique_ptr<void, ProfileDeleter>;
using TransformHandle = std::unique_ptr<void, TransformDeleter>;

// The working space: Display P3 primaries, D65, linear. Every decoder path
// lands here, which is what lets the look, the gain map and the encoders
// assume one colour space without asking where the pixels came from.
ProfileHandle linear_display_p3_profile() {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{
      {0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}};
  cmsToneCurve* curve = cmsBuildGamma(nullptr, 1.0);
  if (!curve) throw std::runtime_error("cannot build a linear tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  ProfileHandle profile(cmsCreateRGBProfile(&white, &primaries, curves));
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot build the linear Display P3 profile");
  return profile;
}

float decode_transfer(float encoded, heif_transfer_characteristics transfer) {
  // CICP 0 is reserved and is also what a zero-initialised nclx box yields.
  // Treat it exactly like an explicit "unspecified" rather than falling into
  // the rejection below.
  if (static_cast<int>(transfer) == 0) return srgb_eotf(encoded);
  switch (transfer) {
    case heif_transfer_characteristic_linear:
      return encoded;
    case heif_transfer_characteristic_ITU_R_BT_2100_0_PQ: {
      constexpr float m1 = 2610.0F / 16384.0F;
      constexpr float m2 = 2523.0F / 32.0F;
      constexpr float c1 = 3424.0F / 4096.0F;
      constexpr float c2 = 2413.0F / 128.0F;
      constexpr float c3 = 2392.0F / 128.0F;
      const float p = std::pow(encoded, 1.0F / m2);
      const float normalized_10000_nits =
          std::pow(std::max(p - c1, 0.0F) / std::max(c2 - c3 * p, 1.0e-6F),
                   1.0F / m1);
      return normalized_10000_nits * 10000.0F / kReferenceWhiteNits;
    }
    case heif_transfer_characteristic_ITU_R_BT_2100_0_HLG: {
      constexpr float a = 0.17883277F;
      constexpr float b = 0.28466892F;
      constexpr float c = 0.55991073F;
      constexpr float kNominalPeakNits = 1000.0F;
      constexpr float kSystemGamma = 1.2F;
      const float scene = encoded <= 0.5F
                              ? (encoded * encoded) / 3.0F
                              : (std::exp((encoded - c) / a) + b) / 12.0F;
      const float display = std::pow(std::max(scene, 0.0F), kSystemGamma);
      return display * kNominalPeakNits / kReferenceWhiteNits;
    }
    case heif_transfer_characteristic_IEC_61966_2_1:
      return srgb_eotf(encoded);
    // The four SDR broadcast curves are one function, and it is not sRGB.
    case heif_transfer_characteristic_ITU_R_BT_709_5:
    case heif_transfer_characteristic_ITU_R_BT_601_6:
    case heif_transfer_characteristic_ITU_R_BT_2020_2_10bit:
    case heif_transfer_characteristic_ITU_R_BT_2020_2_12bit:
    // xvYCC and BT.1361 are the same curve with an extended range.
    case heif_transfer_characteristic_IEC_61966_2_4:
    case heif_transfer_characteristic_ITU_R_BT_1361:
      return bt709_inverse_oetf(encoded);
    case heif_transfer_characteristic_ITU_R_BT_470_6_System_M:
      return std::pow(std::max(0.0F, encoded), 2.2F);
    case heif_transfer_characteristic_ITU_R_BT_470_6_System_B_G:
      return std::pow(std::max(0.0F, encoded), 2.8F);
    // 0 and 2 mean "not stated". sRGB is the documented assumption for an
    // 8-bit still image, and saying so here beats a silent default buried in
    // a fallthrough.
    case heif_transfer_characteristic_unspecified:
      return srgb_eotf(encoded);
    default:
      break;
  }
  throw std::runtime_error("unsupported CICP transfer characteristic " +
                           std::to_string(static_cast<int>(transfer)));
}

std::array<float, 3> encoded_to_linear_p3(float r, float g, float b,
                                          heif_color_primaries primaries,
                                          heif_transfer_characteristics transfer) {
  const float R = decode_transfer(r, transfer);
  const float G = decode_transfer(g, transfer);
  const float B = decode_transfer(b, transfer);
  if (static_cast<int>(primaries) == 0) return rec709_to_linear_p3(R, G, B);
  switch (primaries) {
    case heif_color_primaries_SMPTE_EG_432_1:  // Display P3, D65
      return {std::max(0.0F, R), std::max(0.0F, G), std::max(0.0F, B)};
    case heif_color_primaries_ITU_R_BT_2020_2_and_2100_0:
      return rec2020_to_linear_p3(R, G, B);
    case heif_color_primaries_ITU_R_BT_709_5:
    case heif_color_primaries_unspecified:
      return rec709_to_linear_p3(R, G, B);
    default:
      break;
  }
  // Explicit dispatch, not a Rec.709 catch-all: silently treating unknown
  // primaries as Rec.709 is how a wide-gamut capture loses its saturation
  // without anything in the log saying so.
  throw std::runtime_error("unsupported CICP colour primaries " +
                           std::to_string(static_cast<int>(primaries)));
}

// Converts an interleaved 8- or 16-bit RGB buffer through an embedded ICC
// profile into linear Display P3. Little CMS applies the profile's transfer
// curves and primaries in one step, which is the whole point: a Display P3
// JPEG's pure red must land near (1, 0, 0), not at the (0.82, 0.03, 0.02) that
// decoding it as Rec.709 produces.
void convert_rows_with_icc(const std::uint8_t* pixels, std::uint32_t width,
                           std::uint32_t height, std::size_t stride, int bits,
                           const std::vector<std::uint8_t>& icc,
                           FloatImage& out) {
  ProfileHandle source(
      cmsOpenProfileFromMem(icc.data(), static_cast<cmsUInt32Number>(icc.size())));
  if (!source) throw std::runtime_error("embedded ICC profile is unreadable");
  if (cmsGetColorSpace(source.get()) != cmsSigRgbData) {
    throw std::runtime_error("embedded ICC profile is not an RGB profile");
  }
  const ProfileHandle destination = linear_display_p3_profile();
  const TransformHandle transform(cmsCreateTransform(
      source.get(), bits > 8 ? TYPE_RGB_16 : TYPE_RGB_8, destination.get(),
      TYPE_RGB_FLT, INTENT_RELATIVE_COLORIMETRIC, 0));
  if (!transform) throw std::runtime_error("cannot build the ICC colour transform");

  // cmsDoTransform is documented as safe to call concurrently on one
  // transform, so the rows parallelise exactly like the matrix path.
  auto* handle = transform.get();
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const auto* row = pixels + static_cast<std::size_t>(y) * stride;
    float* target = out.pixels.data() + static_cast<std::size_t>(y) * width * 3;
    cmsDoTransform(handle, row, target, width);
    for (std::size_t i = 0; i < static_cast<std::size_t>(width) * 3; ++i) {
      // Out-of-gamut inputs can come back very slightly negative.
      target[i] = std::max(0.0F, target[i]);
    }
  });
}

DecodedImage from_interleaved_rgb(const std::uint8_t* pixels,
                                  std::uint32_t width, std::uint32_t height,
                                  std::size_t stride, int bits, std::string make,
                                  const SourceColor& color = {}) {
  if (!width || !height) throw std::runtime_error("decoded image has invalid dimensions");
  if (!pixels || bits < 1 || bits > 16) {
    throw std::runtime_error("decoded image has invalid RGB depth");
  }
  DecodedImage result;
  result.linear_p3 = FloatImage(width, height, 3);
  result.decode.sensor_width = width;
  result.decode.sensor_height = height;
  result.decode.target_width = width;
  result.decode.target_height = height;
  result.decode.decoded_width = width;
  result.decode.decoded_height = height;

  if (!color.icc.empty()) {
    convert_rows_with_icc(pixels, width, height, stride, bits, color.icc,
                          result.linear_p3);
  } else {
    const bool wide = bits > 8;
    const float max_code = static_cast<float>((1U << bits) - 1U);
    parallel_for_rows(height, [&](const std::uint32_t y) {
      const auto* row = pixels + static_cast<std::size_t>(y) * stride;
      for (std::uint32_t x = 0; x < width; ++x) {
        std::array<float, 3> encoded{};
        for (unsigned c = 0; c < 3; ++c) {
          if (wide) {
            const std::size_t offset = (static_cast<std::size_t>(x) * 3 + c) * 2;
            const auto code = static_cast<std::uint16_t>(
                row[offset] | (static_cast<std::uint16_t>(row[offset + 1]) << 8));
            encoded[c] = code / max_code;
          } else {
            encoded[c] = row[static_cast<std::size_t>(x) * 3 + c] / max_code;
          }
        }
        const auto p3 = encoded_to_linear_p3(encoded[0], encoded[1], encoded[2],
                                             color.primaries, color.transfer);
        for (unsigned c = 0; c < 3; ++c) result.linear_p3.at(x, y, c) = p3[c];
      }
    });
  }
  result.metadata.make = std::move(make);
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
  // The reduction libjpeg actually applied, as num/denom. 8/8 means the image
  // was decoded at full size; anything smaller means the budget forced a
  // downscale and any dimension read from Exif no longer matches the pixels.
  unsigned int scale_num{8};
  unsigned int scale_denom{8};
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
                    JpegDecodeOutput* out) {
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
  info.out_color_space = JCS_RGB;
  // A 50MP camera raw conversion or a 108MP phone shot overruns the raster
  // budget at full size, and rejecting it outright is the wrong answer: the
  // DCT gives us a cheap, exact power-of-two reduction for free. Ask libjpeg
  // for the largest 1/1, 1/2, 1/4, 1/8 scale that fits, which also shrinks the
  // decode itself -- at 1/8 libjpeg never materialises the full-size rows.
  unsigned chosen_num = 0;
  for (const unsigned num : {8U, 4U, 2U, 1U}) {
    info.scale_num = num;
    info.scale_denom = 8;
    jpeg_calc_output_dimensions(&info);
    if (raster_budget_ok(info.output_width, info.output_height)) {
      chosen_num = num;
      break;
    }
  }
  if (chosen_num == 0) {
    set_message(out->message, sizeof(out->message),
                "image exceeds the pixel or memory budget even at 1/8 scale");
    jpeg_destroy_decompress(&info);
    return 1;
  }
  out->scale_num = chosen_num;
  out->scale_denom = 8;
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

DecodedImage decode_jpeg(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  JpegDecodeOutput output{};
  const int failed = jpeg_decode_rgb(bytes.data(), bytes.size(), &output);
  // Ownership transfers here, once the setjmp/longjmp region is behind us.
  const MallocBytes rgb(output.rgb);
  const MallocBytes icc(output.icc);
  const MallocBytes exif(output.exif);
  if (failed != 0) {
    throw std::runtime_error(std::string("JPEG decode: ") + output.message);
  }

  SourceColor color;
  if (output.icc_size != 0) {
    color.icc.assign(icc.get(), icc.get() + output.icc_size);
  }
  auto result = from_interleaved_rgb(
      rgb.get(), output.width, output.height,
      static_cast<std::size_t>(output.width) * 3, 8, "JPEG", color);
  result.decode.resolution_reduced =
      output.scale_num != output.scale_denom;

  // Orientation is normalised into the pixels rather than carried forward: a
  // phone's landscape-stored portrait used to be exported with orientation 1
  // and never rotated, so both the preview and the exported file were on
  // their side and the reported width and height were the wrong way round.
  const auto orientation =
      output.exif_size == 0
          ? std::nullopt
          : read_exif_orientation(exif.get(), output.exif_size);
  if (orientation && *orientation != 1) {
    result.linear_p3 = apply_exif_orientation(std::move(result.linear_p3),
                                              *orientation);
  }
  result.metadata.orientation = 1;
  return result;
}

// --- PNG -------------------------------------------------------------------

struct PngReadState {
  const unsigned char* data{};
  std::size_t size{};
  std::size_t offset{};
};

struct PngDecodeOutput {
  unsigned char* rgb{};
  std::size_t rgb_size{};
  unsigned char* icc{};
  unsigned int icc_size{};
  unsigned int width{};
  unsigned int height{};
  int bits{};
  // 1 when the image was decoded at full size; >1 is the integer box-average
  // factor the raster budget forced.
  std::uint32_t downscale{1};
  char message[256]{};
};

void png_read_from_memory(png_structp png, png_bytep target, png_size_t length) {
  auto* state = static_cast<PngReadState*>(png_get_io_ptr(png));
  if (state == nullptr || state->offset + length > state->size) {
    png_error(png, "read past the end of the PNG");
    return;
  }
  std::memcpy(target, state->data + state->offset, length);
  state->offset += length;
}

void png_warn(png_structp, png_const_charp) {}

// Same C-style discipline as the JPEG path: libpng's error handler longjmps,
// so nothing with a destructor may be alive in this frame.
//
// This is also where the 16-bit fix lives. The old code went through libpng's
// simplified API with PNG_FORMAT_RGB, which is 8-bit unconditionally, so a
// legitimate 16-bit PNG lost 8 bits per channel -- 65,536 code values reduced
// to 256 -- before the pipeline saw a single pixel, and no amount of 10-bit
// output could bring the gradients back.
int png_decode_rgb(const unsigned char* data, std::size_t size,
                   PngDecodeOutput* out) {
  if (size < 8 || png_sig_cmp(data, 0, 8) != 0) {
    set_message(out->message, sizeof(out->message), "not a PNG file");
    return 1;
  }
  png_structp png =
      png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, nullptr, png_warn);
  if (png == nullptr) {
    set_message(out->message, sizeof(out->message), "cannot create a PNG reader");
    return 1;
  }
  png_infop info = png_create_info_struct(png);
  if (info == nullptr) {
    png_destroy_read_struct(&png, nullptr, nullptr);
    set_message(out->message, sizeof(out->message), "cannot create PNG info");
    return 1;
  }
  PngReadState state{data, size, 0};
  // volatile: this is assigned after setjmp and read in the longjmp handler,
  // and a non-volatile automatic whose value changed in between is
  // indeterminate once the jump has happened.
  png_bytep* volatile rows = nullptr;
  // Scratch for the streaming downscale path below; same discipline.
  unsigned char* volatile src_row = nullptr;
  std::uint64_t* volatile accum = nullptr;

  if (setjmp(png_jmpbuf(png))) {
    png_destroy_read_struct(&png, &info, nullptr);
    std::free(rows);
    std::free(src_row);
    std::free(accum);
    std::free(out->rgb);
    std::free(out->icc);
    out->rgb = nullptr;
    out->rgb_size = 0;
    out->icc = nullptr;
    out->icc_size = 0;
    if (out->message[0] == '\0') {
      set_message(out->message, sizeof(out->message), "PNG decode failed");
    }
    return 1;
  }

  png_set_read_fn(png, &state, png_read_from_memory);
  png_read_info(png, info);

  png_uint_32 width = 0;
  png_uint_32 height = 0;
  int bit_depth = 0;
  int color_type = 0;
  int interlace_type = PNG_INTERLACE_NONE;
  png_get_IHDR(png, info, &width, &height, &bit_depth, &color_type,
               &interlace_type, nullptr, nullptr);

  // PNG has no equivalent of the JPEG DCT scale, so an oversized image is
  // box-averaged by an integer factor while it streams in: only one source row
  // and one accumulator row are ever resident, so peak memory tracks the
  // *output* size, not the input. Interlaced PNGs are the exception -- libpng
  // can only deliver those through png_read_image, which needs the full raster
  // up front, and they are vanishingly rare at these dimensions.
  std::uint32_t factor = 1;
  while (!raster_budget_ok((width + factor - 1) / factor,
                           (height + factor - 1) / factor)) {
    if (factor >= 64) {
      set_message(out->message, sizeof(out->message),
                  "image exceeds the pixel or memory budget");
      png_error(png, "budget");
    }
    ++factor;
  }
  if (factor > 1 && interlace_type != PNG_INTERLACE_NONE) {
    set_message(out->message, sizeof(out->message),
                "interlaced image exceeds the pixel or memory budget");
    png_error(png, "budget");
  }

  if (color_type == PNG_COLOR_TYPE_PALETTE) png_set_palette_to_rgb(png);
  if (color_type == PNG_COLOR_TYPE_GRAY && bit_depth < 8) {
    png_set_expand_gray_1_2_4_to_8(png);
  }
  if (png_get_valid(png, info, PNG_INFO_tRNS) != 0) png_set_tRNS_to_alpha(png);
  if ((color_type & PNG_COLOR_MASK_COLOR) == 0) png_set_gray_to_rgb(png);
  png_set_strip_alpha(png);
  if (bit_depth == 16) {
    // PNG samples are big-endian on the wire; the rest of this file reads
    // 16-bit samples little-endian, and so does Little CMS's TYPE_RGB_16.
    png_set_swap(png);
  }
  png_set_interlace_handling(png);
  png_read_update_info(png, info);

  const int out_bits = bit_depth == 16 ? 16 : 8;
  const std::size_t row_bytes = png_get_rowbytes(png, info);
  if (row_bytes != static_cast<std::size_t>(width) * 3 *
                       (out_bits == 16 ? 2U : 1U)) {
    set_message(out->message, sizeof(out->message),
                "unsupported PNG channel layout");
    png_error(png, "layout");
  }

  const bool wide = out_bits == 16;
  const std::uint32_t out_width = (width + factor - 1) / factor;
  const std::uint32_t out_height = (height + factor - 1) / factor;
  const std::size_t out_row_bytes =
      static_cast<std::size_t>(out_width) * 3 * (wide ? 2U : 1U);
  out->rgb_size = out_row_bytes * out_height;
  out->rgb = static_cast<unsigned char*>(std::malloc(out->rgb_size));
  if (out->rgb == nullptr) {
    set_message(out->message, sizeof(out->message), "out of memory");
    png_error(png, "allocation");
  }

  if (factor == 1) {
    rows = static_cast<png_bytep*>(std::malloc(sizeof(png_bytep) * height));
    if (rows == nullptr) {
      set_message(out->message, sizeof(out->message), "out of memory");
      png_error(png, "allocation");
    }
    for (png_uint_32 y = 0; y < height; ++y) rows[y] = out->rgb + y * row_bytes;
    png_read_image(png, rows);
  } else {
    const std::size_t accum_samples = static_cast<std::size_t>(out_width) * 3;
    src_row = static_cast<unsigned char*>(std::malloc(row_bytes));
    accum = static_cast<std::uint64_t*>(
        std::malloc(accum_samples * sizeof(std::uint64_t)));
    if (src_row == nullptr || accum == nullptr) {
      set_message(out->message, sizeof(out->message), "out of memory");
      png_error(png, "allocation");
    }
    for (png_uint_32 y = 0; y < height; ++y) {
      const std::uint32_t out_y = y / factor;
      if (y % factor == 0) {
        std::memset(accum, 0, accum_samples * sizeof(std::uint64_t));
      }
      png_read_row(png, src_row, nullptr);
      for (png_uint_32 x = 0; x < width; ++x) {
        const std::size_t base = static_cast<std::size_t>(x / factor) * 3;
        for (unsigned c = 0; c < 3; ++c) {
          const std::size_t at = (static_cast<std::size_t>(x) * 3 + c) *
                                 (wide ? 2U : 1U);
          const std::uint32_t sample =
              wide ? static_cast<std::uint32_t>(
                         src_row[at] | (static_cast<std::uint32_t>(
                                            src_row[at + 1]) << 8))
                   : src_row[at];
          accum[base + c] += sample;
        }
      }
      // Flush once the last source row of this block has landed. The final
      // block is short when the dimensions are not a multiple of the factor,
      // so the divisor is the actual contributing pixel count, not factor^2.
      const bool last_in_block = (y + 1) % factor == 0 || y + 1 == height;
      if (!last_in_block) continue;
      const std::uint64_t rows_used =
          static_cast<std::uint64_t>(y % factor) + 1;
      auto* target = out->rgb + static_cast<std::size_t>(out_y) * out_row_bytes;
      for (std::uint32_t ox = 0; ox < out_width; ++ox) {
        const std::uint64_t cols_used =
            std::min<std::uint64_t>(factor, width - static_cast<std::uint64_t>(ox) * factor);
        const std::uint64_t divisor = rows_used * cols_used;
        for (unsigned c = 0; c < 3; ++c) {
          const std::uint64_t mean =
              (accum[static_cast<std::size_t>(ox) * 3 + c] + divisor / 2) / divisor;
          if (wide) {
            const std::size_t at = (static_cast<std::size_t>(ox) * 3 + c) * 2;
            target[at] = static_cast<unsigned char>(mean & 0xFFU);
            target[at + 1] = static_cast<unsigned char>((mean >> 8) & 0xFFU);
          } else {
            target[static_cast<std::size_t>(ox) * 3 + c] =
                static_cast<unsigned char>(mean);
          }
        }
      }
    }
  }
  png_read_end(png, info);

  char* profile_name = nullptr;
  int compression = 0;
  png_bytep profile = nullptr;
  png_uint_32 profile_size = 0;
  if (png_get_iCCP(png, info, &profile_name, &compression, &profile,
                   &profile_size) == PNG_INFO_iCCP &&
      profile != nullptr && profile_size != 0) {
    auto* copy = static_cast<unsigned char*>(std::malloc(profile_size));
    if (copy != nullptr) {
      std::memcpy(copy, profile, profile_size);
      out->icc = copy;
      out->icc_size = profile_size;
    }
  }

  out->width = out_width;
  out->height = out_height;
  out->bits = out_bits;
  out->downscale = factor;
  std::free(rows);
  std::free(src_row);
  std::free(accum);
  png_destroy_read_struct(&png, &info, nullptr);
  return 0;
}

DecodedImage decode_png(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  PngDecodeOutput output{};
  const int failed = png_decode_rgb(bytes.data(), bytes.size(), &output);
  const MallocBytes rgb(output.rgb);
  const MallocBytes icc(output.icc);
  if (failed != 0) {
    throw std::runtime_error(std::string("PNG decode: ") + output.message);
  }
  SourceColor color;
  if (output.icc_size != 0) {
    color.icc.assign(icc.get(), icc.get() + output.icc_size);
  }
  const std::size_t stride =
      static_cast<std::size_t>(output.width) * 3 * (output.bits == 16 ? 2U : 1U);
  auto result = from_interleaved_rgb(rgb.get(), output.width, output.height,
                                     stride, output.bits, "PNG", color);
  result.decode.resolution_reduced = output.downscale > 1;
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

DecodedImage decode_heif_rgb_handle(const heif_image_handle* handle, std::string make) {
  SourceColor color;
  heif_color_profile_nclx* profile_raw = nullptr;
  const auto profile_error = heif_image_handle_get_nclx_color_profile(handle, &profile_raw);
  const bool has_nclx = profile_error.code == heif_error_Ok && profile_raw != nullptr;
  if (has_nclx) {
    color.primaries = profile_raw->color_primaries;
    color.transfer = profile_raw->transfer_characteristics;
    heif_nclx_color_profile_free(profile_raw);
  } else if (heif_image_handle_get_color_profile_type(handle) ==
             heif_color_profile_type_prof) {
    // No CICP, but an ICC profile: read it rather than assuming Rec.709/sRGB.
    const std::size_t size = heif_image_handle_get_raw_color_profile_size(handle);
    if (size != 0 && size <= (4U << 20U)) {
      color.icc.resize(size);
      if (heif_image_handle_get_raw_color_profile(handle, color.icc.data()).code !=
          heif_error_Ok) {
        color.icc.clear();
      }
    }
  }

  const bool wide = heif_image_handle_get_luma_bits_per_pixel(handle) > 8;
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
                               wide ? heif_chroma_interleaved_RRGGBB_LE
                                    : heif_chroma_interleaved_RGB,
                               options.get()),
             "HEIC decode");
  std::unique_ptr<heif_image, ImageDeleter> image(image_raw);
  bool resolution_reduced = false;
  {
    // libheif has no scaled-decode entry point, so unlike JPEG the full raster
    // is already resident here. The budget still has to hold for the float
    // working buffer that follows -- it is the larger of the two -- so shrink
    // in place and release the oversized original before converting.
    const int full_width = heif_image_get_width(image.get(), heif_channel_interleaved);
    const int full_height = heif_image_get_height(image.get(), heif_channel_interleaved);
    if (full_width > 0 && full_height > 0 &&
        !raster_budget_ok(static_cast<std::uint64_t>(full_width),
                          static_cast<std::uint64_t>(full_height))) {
      std::uint32_t factor = 2;
      while (factor <= 64 &&
             !raster_budget_ok((static_cast<std::uint64_t>(full_width) + factor - 1) / factor,
                               (static_cast<std::uint64_t>(full_height) + factor - 1) / factor)) {
        ++factor;
      }
      if (factor > 64) {
        throw std::runtime_error("HEIC image exceeds the pixel or memory budget");
      }
      heif_image* scaled_raw = nullptr;
      check_heif(heif_image_scale_image(
                     image.get(), &scaled_raw,
                     std::max(1, full_width / static_cast<int>(factor)),
                     std::max(1, full_height / static_cast<int>(factor)), nullptr),
                 "HEIC downscale");
      image.reset(scaled_raw);
      resolution_reduced = true;
    }
  }
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
  check_raster_budget(static_cast<std::uint32_t>(width),
                      static_cast<std::uint32_t>(height));
  auto result = from_interleaved_rgb(
      rgb, static_cast<std::uint32_t>(width),
      static_cast<std::uint32_t>(height),
      static_cast<std::size_t>(stride), bits, std::move(make), color);
  result.decode.resolution_reduced = resolution_reduced;
  return result;
}

DecodedImage decode_adaptive_heic(const std::vector<std::uint8_t>& bytes,
                                heif_context* context) {
  const auto inspection = inspect_heif(bytes);
  if (!inspection.structurally_valid || !inspection.has_tmap_brand ||
      !inspection.has_tmap_item || !inspection.has_dimg_reference) {
    throw std::runtime_error("Adaptive HDR HEIC has invalid tmap structure");
  }
  const auto references = find_tmap_references(bytes);
  const auto metadata = parse_tmap_payload(extract_tmap_payload(bytes));

  heif_image_handle* base_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context, references.base_id, &base_handle_raw),
             "get Adaptive HDR base image");
  std::unique_ptr<heif_image_handle, HandleDeleter> base_handle(base_handle_raw);
  auto result = decode_heif_rgb_handle(base_handle.get(), "HEIC Adaptive HDR");

  heif_image_handle* gain_handle_raw = nullptr;
  check_heif(heif_context_get_image_handle(context, references.gain_id, &gain_handle_raw),
             "get Adaptive HDR Gain Map");
  std::unique_ptr<heif_image_handle, HandleDeleter> gain_handle(gain_handle_raw);
  heif_image* gain_raw = nullptr;
  check_heif(heif_decode_image(gain_handle.get(), &gain_raw, heif_colorspace_YCbCr,
                               heif_chroma_420, nullptr),
             "decode Adaptive HDR Gain Map");
  std::unique_ptr<heif_image, ImageDeleter> gain_image(gain_raw);
  const int gain_width = heif_image_get_width(gain_image.get(), heif_channel_Y);
  const int gain_height = heif_image_get_height(gain_image.get(), heif_channel_Y);
  const int gain_bits =
      heif_image_get_bits_per_pixel_range(gain_image.get(), heif_channel_Y);
  int gain_stride = 0;
  const auto* gain_plane =
      heif_image_get_plane_readonly(gain_image.get(), heif_channel_Y, &gain_stride);
  if (!gain_plane || gain_width <= 0 || gain_height <= 0 || gain_stride <= 0 ||
      gain_bits < 1 || gain_bits > 16 ||
      gain_width > static_cast<int>(result.linear_p3.width) ||
      gain_height > static_cast<int>(result.linear_p3.height)) {
    throw std::runtime_error("Adaptive HDR Gain Map has invalid dimensions or depth");
  }

  FloatImage gain(static_cast<std::uint32_t>(gain_width),
                  static_cast<std::uint32_t>(gain_height), 1);
  const float gain_max = static_cast<float>((1U << gain_bits) - 1U);
  for (int y = 0; y < gain_height; ++y) {
    const auto* row = gain_plane + static_cast<std::size_t>(y) * gain_stride;
    for (int x = 0; x < gain_width; ++x) {
      std::uint16_t code = row[x];
      if (gain_bits > 8) {
        code = static_cast<std::uint16_t>(row[x * 2] |
                                         (static_cast<std::uint16_t>(row[x * 2 + 1]) << 8));
      }
      gain.at(static_cast<std::uint32_t>(x), static_cast<std::uint32_t>(y), 0) =
          code / gain_max;
    }
  }
  const float alternate_headroom =
      static_cast<float>(metadata.alternate_headroom.numerator) /
      static_cast<float>(metadata.alternate_headroom.denominator);
  result.linear_p3 = reconstruct_gain_map(result.linear_p3, gain, metadata,
                                          alternate_headroom);
  return result;
}

DecodedImage decode_heic(const std::filesystem::path& path) {
  const auto bytes = read_binary_file(path);
  std::unique_ptr<heif_context, ContextDeleter> context(heif_context_alloc());
  if (!context) throw std::runtime_error("cannot allocate HEIC decoder");
  check_heif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(), bytes.size(), nullptr),
             "HEIC open");
  const auto inspection = inspect_heif(bytes);
  if (inspection.has_tmap_brand || inspection.has_tmap_item) {
    return decode_adaptive_heic(bytes, context.get());
  }
  heif_image_handle* handle_raw = nullptr;
  check_heif(heif_context_get_primary_image_handle(context.get(), &handle_raw),
             "HEIC primary image");
  std::unique_ptr<heif_image_handle, HandleDeleter> handle(handle_raw);
  return decode_heif_rgb_handle(handle.get(), "HEIC");
}

}  // namespace

DecodedImage decode_image(const std::filesystem::path& path, const RawDecodeOptions& options) {
  const auto ext = lower_extension(path);
  if (ext == ".arw" || ext == ".dng") return decode_raw(path, options);
  if (ext == ".jpg" || ext == ".jpeg") {
    // A JPEG/R carries an SDR primary plus a gain map. Reading only the primary
    // would discard the captured highlight range before any look decision, so
    // the gain map is applied first and the plain-JPEG path is the fallback.
    if (is_ultrahdr_jpeg_file(path)) {
      try {
        return decode_ultrahdr(path);
      } catch (const std::exception&) {
        // A malformed gain map must not make an otherwise valid JPEG unusable.
      }
    }
    return decode_jpeg(path);
  }
  if (ext == ".png") return decode_png(path);
  if (ext == ".heic" || ext == ".heif") return decode_heic(path);
  throw std::invalid_argument("unsupported input format: " + ext);
}

std::vector<std::uint8_t> encode_preview_jpeg(const std::filesystem::path& path,
                                              std::uint32_t max_edge,
                                              int quality,
                                              const RawDecodeOptions& options) {
  if (max_edge == 0 || max_edge > 8192) {
    throw std::invalid_argument("preview max edge must be in [1,8192]");
  }
  auto decoded = decode_image(path, options);
  // Identical policy to the --preview-max-edge conversion path: repeated 2x2
  // area reduction in linear light, then one bilinear step to the exact size.
  auto source = resample_to_max_edge(std::move(decoded.linear_p3), max_edge);
  const auto width = source.width;
  const auto height = source.height;

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
            std::clamp(srgb_oetf(srgb[c]), 0.0F, 1.0F) * 255.0F));
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
  return result;
}

}  // namespace hyperdr
