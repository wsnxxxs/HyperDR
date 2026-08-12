#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/transfer.hpp"

#include <libheif/heif.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

hyperdr::FloatImage make_synthetic(std::uint32_t width, std::uint32_t height) {
  hyperdr::FloatImage linear(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const float v = 0.02F + 5.0F * x / static_cast<float>(width - 1);
      linear.at(x, y, 0) = v;
      linear.at(x, y, 1) = v * (0.65F + 0.25F * y / height);
      linear.at(x, y, 2) = v * 0.4F;
    }
  }
  return linear;
}

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

float mean_luminance(const hyperdr::FloatImage& image) {
  double total = 0.0;
  const std::size_t count = static_cast<std::size_t>(image.width) * image.height;
  for (std::size_t i = 0; i < count; ++i) {
    total += 0.2289746 * image.pixels[i * 3] +
             0.6917385 * image.pixels[i * 3 + 1] +
             0.0792869 * image.pixels[i * 3 + 2];
  }
  return count == 0 ? 0.0F : static_cast<float>(total / count);
}

hyperdr::DecodedImage decode_encoded_input(const std::vector<std::uint8_t>& bytes,
                                           const char* label,
                                           const char* extension = ".heic") {
  const auto path = std::filesystem::temp_directory_path() /
      (std::string("hyperdr-codec-input-") + label + extension);
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    auto decoded = hyperdr::decode_image(path);
    std::filesystem::remove(path);
    return decoded;
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

hyperdr::DecodedImage decode_ultrahdr_input(const std::vector<std::uint8_t>& bytes) {
  const auto path =
      std::filesystem::temp_directory_path() / "hyperdr-codec-input-ultrahdr.jpg";
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    auto decoded = hyperdr::decode_ultrahdr(path);
    std::filesystem::remove(path);
    return decoded;
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

void require_linear_round_trip(const hyperdr::DecodedImage& decoded,
                               const hyperdr::FloatImage& expected,
                               const char* message) {
  require(decoded.linear_p3.width == expected.width &&
              decoded.linear_p3.height == expected.height,
          "decoded HDR input has wrong dimensions");
  const float expected_mean = mean_luminance(expected);
  const float decoded_mean = mean_luminance(decoded.linear_p3);
  const float ratio = decoded_mean / std::max(expected_mean, 1.0e-6F);
  if (!(ratio > 0.80F && ratio < 1.20F)) {
    std::cerr << message << ": luminance ratio=" << ratio << '\n';
    throw std::runtime_error(message);
  }
}

// --- 4:2:2 HLG input -------------------------------------------------------
//
// Every encoding this project writes is 4:2:0 or interleaved RGB, so no HyperDR
// output can stand in for the one HDR input shape cameras actually produce:
// Sony's HEIF stills are Main 4:2:2 10 HLG. Decoding those needs libheif's
// 4:2:2 chroma upsampling *and* an HEVC decoder that implements the range
// extensions, neither of which any other test touches. The fixture is therefore
// built here through libheif's own x265 `chroma` parameter.

struct TestContextDeleter {
  void operator()(heif_context* p) const { if (p) heif_context_free(p); }
};
struct TestEncoderDeleter {
  void operator()(heif_encoder* p) const { if (p) heif_encoder_release(p); }
};
struct TestImageDeleter {
  void operator()(heif_image* p) const { if (p) heif_image_release(p); }
};
struct TestHandleDeleter {
  void operator()(heif_image_handle* p) const { if (p) heif_image_handle_release(p); }
};
struct TestEncodingOptionsDeleter {
  void operator()(heif_encoding_options* p) const {
    if (p) heif_encoding_options_free(p);
  }
};

void require_heif(const heif_error& error, const char* operation) {
  if (error.code == heif_error_Ok) return;
  throw std::runtime_error(std::string(operation) + ": " +
                           (error.message ? error.message : "unknown libheif error"));
}

heif_error collect_heif_bytes(heif_context*, const void* data, size_t size, void* user) {
  try {
    auto& out = *static_cast<std::vector<std::uint8_t>*>(user);
    const auto* bytes = static_cast<const std::uint8_t*>(data);
    out.insert(out.end(), bytes, bytes + size);
    return {heif_error_Ok, heif_suberror_Unspecified, "Success"};
  } catch (...) {
    // Never allow a C++ exception to cross libheif's C callback boundary.
    return {heif_error_Encoding_error, heif_suberror_Unspecified, "fixture write failed"};
  }
}

// Encodes `linear` (linear Display P3, 1.0 = diffuse white) as a 10-bit BT.2100
// HLG HEIC with 4:2:2 chroma. Returns an empty vector when the x265 build in use
// cannot do 4:2:2 or Main10, which is reported rather than treated as a failure,
// exactly like the existing Main10 round trips below.
std::vector<std::uint8_t> encode_hlg_422(const hyperdr::FloatImage& linear) {
  std::unique_ptr<heif_context, TestContextDeleter> context(heif_context_alloc());
  require(context != nullptr, "cannot allocate the 4:2:2 fixture context");
  heif_encoder* encoder_raw = nullptr;
  require_heif(heif_context_get_encoder_for_format(context.get(), heif_compression_HEVC,
                                                   &encoder_raw),
               "get the 4:2:2 fixture encoder");
  std::unique_ptr<heif_encoder, TestEncoderDeleter> encoder(encoder_raw);
  require_heif(heif_encoder_set_lossy_quality(encoder.get(), 95),
               "set the 4:2:2 fixture quality");
  // Not every x265 build exposes 4:2:2. A refusal here means the fixture cannot
  // be produced, not that the decoder under test is broken.
  if (heif_encoder_set_parameter_string(encoder.get(), "chroma", "422").code !=
      heif_error_Ok) {
    return {};
  }

  heif_image* image_raw = nullptr;
  require_heif(heif_image_create(static_cast<int>(linear.width),
                                 static_cast<int>(linear.height), heif_colorspace_RGB,
                                 heif_chroma_interleaved_RRGGBB_LE, &image_raw),
               "create the 4:2:2 fixture image");
  std::unique_ptr<heif_image, TestImageDeleter> image(image_raw);
  require_heif(heif_image_add_plane(image.get(), heif_channel_interleaved,
                                    static_cast<int>(linear.width),
                                    static_cast<int>(linear.height), 10),
               "allocate the 4:2:2 fixture plane");
  int stride = 0;
  auto* plane = heif_image_get_plane(image.get(), heif_channel_interleaved, &stride);
  require(plane != nullptr && stride > 0, "4:2:2 fixture plane is unavailable");
  constexpr unsigned max_code = (1U << 10U) - 1U;
  for (std::uint32_t y = 0; y < linear.height; ++y) {
    auto* row = reinterpret_cast<std::uint16_t*>(plane + static_cast<std::size_t>(y) * stride);
    for (std::uint32_t x = 0; x < linear.width; ++x) {
      const auto wide = hyperdr::p3_to_rec2020(linear.at(x, y, 0), linear.at(x, y, 1),
                                               linear.at(x, y, 2));
      for (unsigned channel = 0; channel < 3; ++channel) {
        const float encoded = hyperdr::hlg_oetf(std::max(0.0F, wide[channel]));
        row[x * 3 + channel] = static_cast<std::uint16_t>(
            std::lround(std::clamp(encoded, 0.0F, 1.0F) * max_code));
      }
    }
  }

  heif_color_profile_nclx nclx{};
  nclx.version = 1;
  nclx.color_primaries = heif_color_primaries_ITU_R_BT_2020_2_and_2100_0;
  nclx.transfer_characteristics = heif_transfer_characteristic_ITU_R_BT_2100_0_HLG;
  nclx.matrix_coefficients = heif_matrix_coefficients_ITU_R_BT_2020_2_non_constant_luminance;
  nclx.full_range_flag = 1;
  require_heif(heif_image_set_nclx_color_profile(image.get(), &nclx),
               "set the 4:2:2 fixture nclx");

  std::unique_ptr<heif_encoding_options, TestEncodingOptionsDeleter> options(
      heif_encoding_options_alloc());
  require(options != nullptr, "cannot allocate the 4:2:2 fixture options");
  options->output_nclx_profile = &nclx;
  heif_image_handle* handle_raw = nullptr;
  const auto encoded = heif_context_encode_image(context.get(), image.get(),
                                                 encoder.get(), options.get(),
                                                 &handle_raw);
  if (encoded.code != heif_error_Ok) {
    // Same treatment as the Main10 round trips: a bit-depth or chroma refusal
    // from x265 is an absent fixture, anything else is a real failure.
    const std::string message = encoded.message ? encoded.message : "";
    if (message.find("Bit depth not supported") != std::string::npos ||
        message.find("chroma") != std::string::npos) {
      return {};
    }
    require_heif(encoded, "encode the 4:2:2 fixture");
  }
  std::unique_ptr<heif_image_handle, TestHandleDeleter> handle(handle_raw);
  require_heif(heif_context_set_primary_image(context.get(), handle.get()),
               "set the 4:2:2 fixture primary image");

  std::vector<std::uint8_t> bytes;
  heif_writer writer{1, &collect_heif_bytes};
  require_heif(heif_context_write(context.get(), &writer, &bytes),
               "write the 4:2:2 fixture");
  return bytes;
}

// Proves the fixture really is 4:2:2 before its decode is used as evidence:
// asking libheif for the native colourspace is the only way to see the chroma
// format the conversion to RGB would otherwise hide.
void require_chroma_422(const std::vector<std::uint8_t>& bytes) {
  std::unique_ptr<heif_context, TestContextDeleter> context(heif_context_alloc());
  require(context != nullptr, "cannot allocate the 4:2:2 inspection context");
  require_heif(heif_context_read_from_memory_without_copy(context.get(), bytes.data(),
                                                          bytes.size(), nullptr),
               "read the 4:2:2 fixture");
  heif_image_handle* handle_raw = nullptr;
  require_heif(heif_context_get_primary_image_handle(context.get(), &handle_raw),
               "get the 4:2:2 fixture primary handle");
  std::unique_ptr<heif_image_handle, TestHandleDeleter> handle(handle_raw);
  heif_image* native_raw = nullptr;
  require_heif(heif_decode_image(handle.get(), &native_raw, heif_colorspace_undefined,
                                 heif_chroma_undefined, nullptr),
               "decode the 4:2:2 fixture natively");
  std::unique_ptr<heif_image, TestImageDeleter> native(native_raw);
  const auto chroma = heif_image_get_chroma_format(native.get());
  if (chroma != heif_chroma_422) {
    throw std::runtime_error("the 4:2:2 fixture was not encoded as 4:2:2 (chroma=" +
                             std::to_string(static_cast<int>(chroma)) + ")");
  }
  require(heif_image_handle_get_luma_bits_per_pixel(handle.get()) == 10,
          "the 4:2:2 fixture is not 10-bit");
}

// An input's declared headroom, and the preview divisor that follows from it.
//
// `bytes` must be a gain-map file, so that the same pixels can be read both as
// HDR and -- through `ignore_embedded_gain_map` -- as the SDR base underneath.
// That is the sharpest available test of the gate: one file, two readings, and
// only the HDR one may be scaled.
void check_input_headroom(const std::vector<std::uint8_t>& bytes, const char* label,
                          const char* extension) {
  const auto path = std::filesystem::temp_directory_path() /
      (std::string("hyperdr-codec-headroom-") + label + extension);
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    hyperdr::RawDecodeOptions base_only;
    base_only.ignore_embedded_gain_map = true;

    const auto hdr = hyperdr::decode_image(path);
    require(hdr.hdr_headroom > 1.0F, "a gain-map input must declare headroom");
    const auto sdr = hyperdr::decode_image(path, base_only);
    require(sdr.hdr_headroom == 1.0F,
            "the SDR base of a gain-map input must declare no headroom");

    const auto hdr_preview = hyperdr::encode_preview_jpeg(path, 256, 85);
    require(hdr_preview.scale > 1.0F,
            "an HDR input's preview must be divided so its highlights survive");
    const auto sdr_preview = hyperdr::encode_preview_jpeg(path, 256, 85, base_only);
    require(sdr_preview.scale == 1.0F,
            "an SDR input's preview must not be divided");
    std::filesystem::remove(path);
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

// Decodes the primary image and checks CICP plus non-inverted channel order at a
// bright sample. This is the regression the 8-bit default path was missing: a file
// can be structurally perfect and still carry an undecodable bitstream (for example
// a single-slice NAL beyond libde265's 16 MiB security limit).
void decode_and_check(const std::vector<std::uint8_t>& bytes, std::uint32_t width, std::uint32_t height) {
  heif_context* context = heif_context_alloc();
  require(context != nullptr, "cannot allocate decode context");
  try {
    auto err = heif_context_read_from_memory_without_copy(context, bytes.data(), bytes.size(), nullptr);
    require(err.code == heif_error_Ok, "cannot read encoded HEIC");
    heif_image_handle* primary = nullptr;
    err = heif_context_get_primary_image_handle(context, &primary);
    require(err.code == heif_error_Ok && primary, "cannot get primary image");

    heif_color_profile_nclx* nclx = nullptr;
    err = heif_image_handle_get_nclx_color_profile(primary, &nclx);
    const bool nclx_ok = err.code == heif_error_Ok && nclx &&
                         nclx->color_primaries == heif_color_primaries_SMPTE_EG_432_1 &&
                         nclx->transfer_characteristics == heif_transfer_characteristic_IEC_61966_2_1 &&
                         nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 &&
                         nclx->full_range_flag == 1 &&
                         heif_image_handle_get_raw_color_profile_size(primary) > 0;
    if (nclx) heif_nclx_color_profile_free(nclx);
    if (!nclx_ok) { heif_image_handle_release(primary); throw std::runtime_error("primary image has incorrect Display P3 CICP"); }

    const bool wide = heif_image_handle_get_luma_bits_per_pixel(primary) > 8;
    heif_image* decoded = nullptr;
    err = heif_decode_image(primary, &decoded, heif_colorspace_RGB,
                            wide ? heif_chroma_interleaved_RRGGBB_LE : heif_chroma_interleaved_RGB, nullptr);
    heif_image_handle_release(primary);
    require(err.code == heif_error_Ok && decoded, "cannot decode primary image");
    require(static_cast<std::uint32_t>(heif_image_get_width(decoded, heif_channel_interleaved)) == width &&
                static_cast<std::uint32_t>(heif_image_get_height(decoded, heif_channel_interleaved)) == height,
            "decoded primary image has wrong dimensions");
    int stride = 0;
    const auto* plane = heif_image_get_plane_readonly(decoded, heif_channel_interleaved, &stride);
    require(plane != nullptr, "decoded primary image has no pixels");
    const std::size_t row = static_cast<std::size_t>(height / 2) * stride;
    const std::size_t x = static_cast<std::size_t>(width - 2) * 3;
    bool ordered = false;
    if (wide) {
      const auto* sample = reinterpret_cast<const std::uint16_t*>(plane + row) + x;
      ordered = sample[0] >= sample[1] && sample[1] >= sample[2];
    } else {
      const auto* sample = plane + row + x;
      ordered = sample[0] >= sample[1] && sample[1] >= sample[2];
    }
    heif_image_release(decoded);
    require(ordered, "primary image color-channel round trip failed");
  } catch (...) {
    heif_context_free(context);
    throw;
  }
  heif_context_free(context);
}

void check_gain_decode(const std::vector<std::uint8_t>& bytes,
                       const hyperdr::FloatImage* expected = nullptr) {
  const auto references = hyperdr::find_tmap_references(bytes);
  heif_context* context = heif_context_alloc();
  require(context != nullptr, "cannot allocate gain decode context");
  try {
    auto error = heif_context_read_from_memory_without_copy(
        context, bytes.data(), bytes.size(), nullptr);
    require(error.code == heif_error_Ok, "cannot read gain-map HEIC");
    heif_image_handle* handle = nullptr;
    error = heif_context_get_image_handle(context, references.gain_id, &handle);
    require(error.code == heif_error_Ok && handle, "cannot get Gain Map handle");

    heif_color_profile_nclx* nclx = nullptr;
    error = heif_image_handle_get_nclx_color_profile(handle, &nclx);
    const bool profile_ok =
        error.code == heif_error_Ok && nclx &&
        nclx->color_primaries == heif_color_primaries_unspecified &&
        nclx->transfer_characteristics == heif_transfer_characteristic_unspecified &&
        nclx->matrix_coefficients == heif_matrix_coefficients_ITU_R_BT_709_5 &&
        nclx->full_range_flag == 1;
    if (nclx) heif_nclx_color_profile_free(nclx);
    if (!profile_ok) {
      heif_image_handle_release(handle);
      throw std::runtime_error("Gain Map nclx is not 2/2/1/full");
    }

    heif_image* decoded = nullptr;
    error = heif_decode_image(handle, &decoded, heif_colorspace_YCbCr,
                              heif_chroma_420, nullptr);
    heif_image_handle_release(handle);
    require(error.code == heif_error_Ok && decoded, "cannot decode Gain Map");
    int y_stride = 0;
    const auto* y_plane =
        heif_image_get_plane_readonly(decoded, heif_channel_Y, &y_stride);
    const int width = heif_image_get_width(decoded, heif_channel_Y);
    const int height = heif_image_get_height(decoded, heif_channel_Y);
    require(y_plane && width > 0 && height > 0 && y_stride >= width,
            "invalid Gain Map luma plane");
    if (expected) {
      require(expected->channels == 1 && expected->width == static_cast<std::uint32_t>(width) &&
                  expected->height == static_cast<std::uint32_t>(height),
              "lossless Gain Map probe has unexpected dimensions");
    }
    int minimum = 255;
    int maximum = 0;
    for (int y = 0; y < height; ++y) {
      for (int x = 0; x < width; ++x) {
        const auto actual = y_plane[y * y_stride + x];
        minimum = std::min(minimum, static_cast<int>(actual));
        maximum = std::max(maximum, static_cast<int>(actual));
        if (expected) {
          const auto wanted = static_cast<std::uint8_t>(std::lround(
              std::clamp(expected->at(static_cast<std::uint32_t>(x),
                                      static_cast<std::uint32_t>(y), 0), 0.0F, 1.0F) * 255.0F));
          if (actual != wanted) {
            throw std::runtime_error(wanted == 0
                ? "lossless Gain Map changed a zero-gain cell"
                : "lossless Gain Map changed an encoded gain code");
          }
        }
      }
    }
    require(minimum <= 16 && maximum >= 239,
            "Gain Map does not retain full-range endpoints");
    for (const auto channel : {heif_channel_Cb, heif_channel_Cr}) {
      int stride = 0;
      const auto* plane = heif_image_get_plane_readonly(decoded, channel, &stride);
      const int cw = heif_image_get_width(decoded, channel);
      const int ch = heif_image_get_height(decoded, channel);
      require(plane && cw > 0 && ch > 0 && stride >= cw,
              "invalid Gain Map chroma plane");
      for (int y = 0; y < ch; y += std::max(1, ch / 32)) {
        for (int x = 0; x < cw; x += std::max(1, cw / 32)) {
          require(std::abs(static_cast<int>(plane[y * stride + x]) - 128) <= 3,
                  "Gain Map chroma is not neutral");
        }
      }
    }
    heif_image_release(decoded);
  } catch (...) {
    heif_context_free(context);
    throw;
  }
  heif_context_free(context);
}
void check_semantic_rejections(const std::vector<std::uint8_t>& bytes) {
  const auto references = hyperdr::find_tmap_references(bytes);
  auto broken_dimg = bytes;
  bool changed = false;
  for (std::size_t i = 0; i + 16 <= broken_dimg.size(); ++i) {
    if (broken_dimg[i] == 0 && broken_dimg[i + 1] == 0 &&
        broken_dimg[i + 2] == 0 && broken_dimg[i + 3] == 16 &&
        broken_dimg[i + 4] == 'd' && broken_dimg[i + 5] == 'i' &&
        broken_dimg[i + 6] == 'm' && broken_dimg[i + 7] == 'g' &&
        broken_dimg[i + 8] == static_cast<std::uint8_t>(references.tmap_id >> 8) &&
        broken_dimg[i + 9] == static_cast<std::uint8_t>(references.tmap_id) &&
        broken_dimg[i + 10] == 0 && broken_dimg[i + 11] == 2 &&
        broken_dimg[i + 12] == static_cast<std::uint8_t>(references.base_id >> 8) &&
        broken_dimg[i + 13] == static_cast<std::uint8_t>(references.base_id) &&
        broken_dimg[i + 14] == static_cast<std::uint8_t>(references.gain_id >> 8) &&
        broken_dimg[i + 15] == static_cast<std::uint8_t>(references.gain_id)) {
      broken_dimg[i + 10] = 0;
      broken_dimg[i + 11] = 3;
      changed = true;
      break;
    }
  }
  require(changed && !hyperdr::inspect_heif(broken_dimg).structurally_valid,
          "grid dimg masked a broken tmap dimg");

  auto colliding_group = bytes;
  changed = false;
  for (std::size_t i = 0; i + 28 <= colliding_group.size(); ++i) {
    if (colliding_group[i + 4] == 'a' && colliding_group[i + 5] == 'l' &&
        colliding_group[i + 6] == 't' && colliding_group[i + 7] == 'r') {
      colliding_group[i + 12] =
          static_cast<std::uint8_t>(references.gain_id >> 24);
      colliding_group[i + 13] =
          static_cast<std::uint8_t>(references.gain_id >> 16);
      colliding_group[i + 14] =
          static_cast<std::uint8_t>(references.gain_id >> 8);
      colliding_group[i + 15] =
          static_cast<std::uint8_t>(references.gain_id);
      changed = true;
      break;
    }
  }
  require(changed && !hyperdr::inspect_heif(colliding_group).structurally_valid,
          "altr group/item ID collision was accepted");
}
void check_structure(const std::vector<std::uint8_t>& bytes, const char* label) {
  const auto inspection = hyperdr::inspect_heif(bytes);
  if (!inspection.structurally_valid || !inspection.has_heic_brand || !inspection.has_tmap_brand ||
      !inspection.has_tmap_item || !inspection.has_dimg_reference || !inspection.has_altr_group ||
      !inspection.has_exif || !inspection.has_xmp) {
    std::cerr << hyperdr::inspection_json(inspection) << '\n';
    throw std::runtime_error(std::string(label) + ": structural verification failed");
  }
  const auto references = hyperdr::find_tmap_references(bytes);
  require(references.tmap_id != 0 && references.base_id != 0 && references.gain_id != 0 &&
              references.base_id != references.gain_id,
          "tmap dimg references are not resolvable");
}

void reconstruct_and_check(const std::vector<std::uint8_t>& bytes, const char* label) {
  const auto temp_heic = std::filesystem::temp_directory_path() / "hyperdr-codec-test.heic";
  const auto temp_tiff = std::filesystem::temp_directory_path() / "hyperdr-codec-test.tiff";
  hyperdr::write_binary_file_atomic(temp_heic, bytes, true);
  hyperdr::reconstruct_heic_to_tiff(temp_heic, temp_tiff);
  const auto tiff = hyperdr::read_binary_file(temp_tiff);
  if (tiff.size() < 140 || tiff[0] != 'I' || tiff[1] != 'I')
    throw std::runtime_error(std::string(label) + ": TIFF reconstruction failed");
  std::filesystem::remove(temp_heic);
  std::filesystem::remove(temp_tiff);
}

// The display curve is a difference between two renders, so the one case whose
// answer is known without a second implementation is a file against itself:
// every headroom must report exactly zero error and identical clamping in both
// arms. That is a weak claim about accuracy and a strong one about wiring - it
// fails if the two arms are decoded or rendered differently, if the statistics
// are read from the wrong arm, or if they are never populated at all.
void display_curve_identity_check(const std::vector<std::uint8_t>& bytes, const char* label) {
  const auto temp_heic = std::filesystem::temp_directory_path() / "hyperdr-display-curve-test.heic";
  hyperdr::write_binary_file_atomic(temp_heic, bytes, true);
  const std::vector<float> headrooms{0.0F, 1.0F, 2.5F};
  const auto result = hyperdr::compare_gain_map_heic_curve(temp_heic, temp_heic, headrooms);
  std::filesystem::remove(temp_heic);

  require(result.points.size() == headrooms.size(),
          "display curve did not report one point per requested headroom");
  for (std::size_t index = 0; index < result.points.size(); ++index) {
    const auto& point = result.points[index];
    const std::string where =
        std::string(label) + " at headroom " + std::to_string(headrooms[index]);
    require(point.headroom_stops == headrooms[index],
            (where + ": headroom was not echoed back").c_str());
    require(point.mae_linear_p3 == 0.0 && point.mse_linear_p3 == 0.0 &&
                point.max_abs_error_linear_p3 == 0.0,
            (where + ": a file compared against itself reported nonzero error").c_str());
    // Measured zeros, not absent counts: the totals have to be populated for the
    // clamp rates the protocol compares between arms to mean anything.
    require(point.total_values > 0 && point.total_pixels > 0,
            (where + ": clamp statistics were not populated").c_str());
    require(point.reference_clamp_values == point.candidate_clamp_values &&
                point.reference_clamp_pixels == point.candidate_clamp_pixels,
            (where + ": identical inputs clamped by different amounts").c_str());
  }
}

// The identity check above passes vacuously if the comparison reports zero for
// everything, so one pair that must differ is measured too: the same base with a
// perturbed Gain Map. This asserts only that the difference is seen and that the
// summaries are mutually consistent; how large it should be is what T6 measures.
void display_curve_difference_check(const std::vector<std::uint8_t>& reference_bytes,
                                    const std::vector<std::uint8_t>& candidate_bytes,
                                    const char* label) {
  const auto directory = std::filesystem::temp_directory_path();
  const auto reference = directory / "hyperdr-display-curve-reference.heic";
  const auto candidate = directory / "hyperdr-display-curve-candidate.heic";
  hyperdr::write_binary_file_atomic(reference, reference_bytes, true);
  hyperdr::write_binary_file_atomic(candidate, candidate_bytes, true);
  const auto result =
      hyperdr::compare_gain_map_heic_curve(reference, candidate, {0.0F, 1.0F, 2.5F});
  std::filesystem::remove(reference);
  std::filesystem::remove(candidate);

  require(result.points.size() == 3, "display curve dropped a requested headroom");
  for (const auto& point : result.points) {
    const std::string where =
        std::string(label) + " at headroom " + std::to_string(point.headroom_stops);
    require(point.max_abs_error_linear_p3 >= point.mae_linear_p3,
            (where + ": maximum error fell below the mean").c_str());
  }
  require(result.points.back().mae_linear_p3 > 0.0,
          (std::string(label) + ": a perturbed Gain Map reported no difference at all").c_str());
}

}  // namespace

int main() {
  try {
    hyperdr::GainMapOptions options;
    options.auto_exposure = false;
    options.auto_headroom = false;
    options.headroom_stops = 3.0F;
    hyperdr::PhotoMetadata metadata;
    metadata.model = "ILCE-7RM5";
    metadata.lens = "Synthetic test lens";
    metadata.iso = 100;

    // Default 8-bit output through the grid path (wider than one 2048 tile), with a
    // full decode and gain-map reconstruction regression, not just structure checks.
    const auto large = make_synthetic(2600, 1408);
    const auto large_gain = hyperdr::make_gain_map(large, options);
    const auto bytes8 = hyperdr::encode_adaptive_heic(large_gain, metadata, 90, 8);
    check_structure(bytes8, "8-bit grid");
    decode_and_check(bytes8, 2600, 1408);
    check_gain_decode(bytes8);
    check_semantic_rejections(bytes8);
    hyperdr::verify_heic_decodable(bytes8);
    reconstruct_and_check(bytes8, "8-bit grid");
    display_curve_identity_check(bytes8, "8-bit grid");

    // Single-tile 8-bit output.
    const auto small = make_synthetic(64, 32);
    const auto small_gain = hyperdr::make_gain_map(small, options);
    const auto ultrahdr = hyperdr::encode_ultrahdr_jpeg(small_gain, metadata, 90);
    require(ultrahdr.size() > 512 && ultrahdr[0] == 0xFF && ultrahdr[1] == 0xD8,
            "Ultra HDR output is not a JPEG/R stream");
    hyperdr::verify_ultrahdr_jpeg(ultrahdr);
    const auto expected_ultrahdr = hyperdr::reconstruct_gain_map(
        small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
        small_gain.headroom_stops);
    require_linear_round_trip(decode_ultrahdr_input(ultrahdr),
                              expected_ultrahdr,
                              "Ultra HDR input did not reconstruct its Gain Map");
    // AVIF is the encoding this project could write but not read, so unlike the
    // other five it had no input round trip: `verify_avif_decodable` only ever
    // proved libavif would open the file, never that HyperDR would.
    const auto expected_avif = hyperdr::reconstruct_gain_map(
        small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
        small_gain.headroom_stops);
    for (const auto encoding :
         {hyperdr::HdrEncoding::AvifPq, hyperdr::HdrEncoding::AvifHlg}) {
      const bool pq = encoding == hyperdr::HdrEncoding::AvifPq;
      const auto avif = hyperdr::encode_avif(small_gain, metadata, 80, encoding);
      require(avif.size() > 32, "AVIF encoder produced an implausibly small file");
      hyperdr::verify_avif_decodable(avif);
      const auto decoded =
          decode_encoded_input(avif, pq ? "avif-pq" : "avif-hlg", ".avif");
      require_linear_round_trip(decoded, expected_avif,
                                pq ? "PQ AVIF input transfer round trip changed brightness"
                                   : "HLG AVIF input transfer round trip changed brightness");
      require(decoded.metadata.model == metadata.model,
              "AVIF input did not carry its camera model back");
      require(decoded.capture.iso && *decoded.capture.iso == 100.0F,
              "AVIF input did not carry its ISO back");
    }
    std::cout << "PQ/HLG AVIF input round trips passed\n";
    auto no_headroom_options = options;
    no_headroom_options.headroom_stops = 0.0F;
    const auto no_headroom_gain = hyperdr::make_gain_map(small, no_headroom_options);
    hyperdr::verify_ultrahdr_jpeg(
        hyperdr::encode_ultrahdr_jpeg(no_headroom_gain, metadata, 20));
    auto lossless_probe = small_gain;
    for (std::size_t i = 0; i < lossless_probe.gain_map.pixels.size(); ++i) {
      const auto code = i % 7 == 0 ? 0U : (i % 11 == 0 ? 255U : static_cast<unsigned>((i * 37U) % 255U));
      lossless_probe.gain_map.pixels[i] = static_cast<float>(code) / 255.0F;
    }
    const auto small8 = hyperdr::encode_adaptive_heic(lossless_probe, metadata, 80, 8);
    check_structure(small8, "8-bit single");
    decode_and_check(small8, 64, 32);
    check_gain_decode(small8, &lossless_probe.gain_map);
    const auto expected_adaptive = hyperdr::reconstruct_gain_map(
        lossless_probe.base_linear, lossless_probe.gain_map,
        lossless_probe.metadata, lossless_probe.headroom_stops);
    require_linear_round_trip(decode_encoded_input(small8, "adaptive"),
                              expected_adaptive,
                              "Adaptive HDR input did not reconstruct its Gain Map");
    // What makes an input HDR is its format, not a percentile of its pixels.
    //
    // This gate is the fix for a real regression: the preview divisor was first
    // chosen from the decoded image's 99.99th percentile, and a RAW decodes
    // above 1.0 whenever white-balance normalisation leaves headroom there. Some
    // frames of a shoot were divided and others were not, and the divided ones
    // spent a quarter of the preview's eight bits on range that auto-exposure
    // was about to remove. `small` reaches 5.0 and is scene-referred, so it is
    // exactly the shape that fooled the percentile rule.
    check_input_headroom(small8, "adaptive-headroom", ".heic");


    // Same base, compressed the same way; only the Gain Map codes move, so any
    // difference the curve reports has to come from the gain path.
    auto perturbed_probe = lossless_probe;
    for (auto& code : perturbed_probe.gain_map.pixels) {
      code = std::min(1.0F, code * 0.5F + 0.25F);
    }
    const auto perturbed8 = hyperdr::encode_adaptive_heic(perturbed_probe, metadata, 80, 8);
    display_curve_identity_check(small8, "8-bit single");
    display_curve_difference_check(small8, perturbed8, "8-bit single, perturbed Gain Map");

    // Single-image BT.2100 exports must be Main10, carry the requested transfer
    // function, remain distinct from gain-map topology, and decode end-to-end.
    try {
      for (const auto encoding : {hyperdr::HdrEncoding::Pq, hyperdr::HdrEncoding::Hlg}) {
        const auto hdr_bytes = hyperdr::encode_hdr_heic(small_gain, metadata, 80, encoding);
        const auto inspection = hyperdr::inspect_heif(hdr_bytes);
        require(inspection.structurally_valid && inspection.has_heic_brand &&
                    !inspection.has_tmap_brand && !inspection.has_tmap_item &&
                    inspection.has_exif && inspection.has_xmp,
                "BT.2100 export has incorrect HEIF topology");
        hyperdr::verify_heic_decodable(hdr_bytes, encoding);
        const auto expected_hdr = hyperdr::reconstruct_gain_map(
            small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
            small_gain.headroom_stops);
        const auto decoded = decode_encoded_input(
            hdr_bytes, encoding == hyperdr::HdrEncoding::Pq ? "pq" : "hlg");
        require_linear_round_trip(
            decoded, expected_hdr,
            encoding == hyperdr::HdrEncoding::Pq
                ? "PQ input transfer round trip changed brightness"
                : "HLG input transfer round trip changed brightness");
        // The HEIF Exif item is prefixed with a four-byte TIFF offset, which is
        // exactly the kind of preamble the reader has to skip. Checking it here
        // keeps the container path honest as well as the AVIF one.
        require(decoded.metadata.model == metadata.model,
                "HEIC input did not carry its camera model back");
        require(decoded.capture.iso && *decoded.capture.iso == 100.0F,
                "HEIC input did not carry its ISO back");
      }
      std::cout << "PQ/HLG Main10 round trips passed\n";
    } catch (const std::exception& e) {
      if (std::string(e.what()).find("Bit depth not supported") == std::string::npos) {
        throw;
      }
      std::cout << "PQ/HLG tests skipped (Main10 x265 unavailable?): " << e.what() << '\n';
    }

    // A camera-shaped HDR input: 10-bit BT.2100 HLG at 4:2:2. This is the only
    // chroma format no HyperDR output can stand in for, and the only one whose
    // decode depends on the HEVC range extensions.
    try {
      const auto hlg422 = encode_hlg_422(small);
      if (hlg422.empty()) {
        std::cout << "4:2:2 HLG input test skipped (x265 cannot encode 4:2:2)\n";
      } else {
        require_chroma_422(hlg422);
        require_linear_round_trip(decode_encoded_input(hlg422, "hlg422"), small,
                                  "4:2:2 HLG input did not decode to its linear values");
        std::cout << "4:2:2 HLG input round trip passed\n";
      }
    } catch (const std::exception& e) {
      if (std::string(e.what()).find("Bit depth not supported") == std::string::npos) {
        throw;
      }
      std::cout << "4:2:2 HLG input test skipped (Main10 x265 unavailable?): "
                << e.what() << '\n';
    }

    // Optional 10-bit round trip; requires a Main10-capable x265, which the stock
    // vcpkg DLL is not. Missing 10-bit support is reported, not treated as failure.
    try {
      const auto bytes10 = hyperdr::encode_adaptive_heic(small_gain, metadata, 80, 10);
      check_structure(bytes10, "10-bit single");
      decode_and_check(bytes10, 64, 32);
      reconstruct_and_check(bytes10, "10-bit single");
      display_curve_identity_check(bytes10, "10-bit single");
      std::cout << "10-bit Main10 round trip passed\n";
    } catch (const std::exception& e) {
      if (std::string(e.what()).find("Bit depth not supported") == std::string::npos) {
        throw;
      }
      std::cout << "10-bit test skipped (Main10 x265 unavailable?): " << e.what() << '\n';
    }

    std::cout << "codec/TMAP integration test passed (" << bytes8.size() << " bytes, grid)\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "codec test failure: " << e.what() << '\n';
    return 1;
  }
}
