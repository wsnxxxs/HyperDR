#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/container/heif_tmap.hpp"
#include "hevc/hevc.hpp"
#include "hyperdr/container/heif_writer.hpp"
#include "internal/icc_profiles.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/transfer.hpp"

#include <avif/avif.h>
#include <png.h>
#include <lcms2.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include "heif_hlg_422.hpp"
#include "heif_native_decode.hpp"

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

void require_hevc_profiles(const std::vector<std::uint8_t>& bytes,
                           bool expect_main10, bool expect_main8) {
  const auto inspection = hyperdr::inspect_heif(bytes);
  bool has_main10 = false;
  bool has_main8 = false;
  for (const auto& box : inspection.boxes) {
    if (box.type != "hvcC") continue;
    require(box.size >= 23 && box.offset + box.size <= bytes.size(),
            "HEIC has an invalid hvcC box");
    const auto profile = bytes[static_cast<std::size_t>(box.offset) + 9] & 31;
    require(profile == 1 || profile == 2,
            "HEIC writer emitted an unexpected HEVC profile");
    require(bytes[static_cast<std::size_t>(box.offset) + 20] != 255,
            "HEIC writer emitted HEVC Level 8.5");
    has_main10 |= profile == 2;
    has_main8 |= profile == 1;
  }
  require(has_main10 == expect_main10 &&
              has_main8 == expect_main8,
          "HEIC writer emitted the wrong HEVC profile");
}

bool contains_text(const std::vector<std::uint8_t>& bytes,
                   std::string_view text) {
  return std::search(bytes.begin(), bytes.end(), text.begin(), text.end()) !=
         bytes.end();
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

std::array<std::uint16_t, 2> expected_content_light(
    const hyperdr::FloatImage& source) {
  // ITU-T H.274 8.10.2 defines MaxCLL from max(R, G, B) in linear light,
  // deliberately allowing saturated colours to exceed their CIE luminance;
  // MaxPALL averages that same per-sample light level over the picture.
  float peak = 0;
  double sum = 0;
  for (unsigned y = 0; y < source.height; ++y)
    for (unsigned x = 0; x < source.width; ++x) {
      const auto rgb = hyperdr::p3_to_rec2020(source.at(x,y,0), source.at(x,y,1), source.at(x,y,2));
      const float light = std::max({0.0F, rgb[0], rgb[1], rgb[2]});
      peak = std::max(peak, light);
      sum += light;
    }
  const auto clamp_light = [](double nits) {
    return static_cast<std::uint16_t>(
        std::clamp(std::ceil(nits), 0.0, 10000.0));
  };
  const double count = static_cast<double>(source.width) * source.height;
  return {clamp_light(peak * hyperdr::kReferenceWhiteNits),
          clamp_light(count > 0 ? sum * hyperdr::kReferenceWhiteNits / count : 0)};
}

void require_content_peak(const hyperdr::DecodedImage& decoded,
                          const hyperdr::FloatImage& source) {
  const auto expected = expected_content_light(source);
  require(decoded.content_peak_nits &&
              std::abs(*decoded.content_peak_nits - expected[0]) < 0.01F,
          "HDR raster lost encoded maxRGB content-light metadata");
  require(decoded.describe_input().content_peak_nits == decoded.content_peak_nits,
          "HDR input description lost content-light metadata");
}

void require_declared_headroom(const hyperdr::DecodedImage& decoded,
                               float expected, const char* message) {
  const float error = std::abs(decoded.hdr_headroom - expected);
  if (decoded.domain != hyperdr::InputDomain::kDisplayReferredHdr ||
      error > std::max(0.05F, expected * 0.01F)) {
    std::cerr << message << ": headroom=" << decoded.hdr_headroom
              << " expected=" << expected << '\n';
    throw std::runtime_error(message);
  }
}

struct PngWriteBuffer {
  std::vector<std::uint8_t> bytes;
};

void png_write_to_vector(png_structp png, png_bytep data, png_size_t size) {
  auto* output = static_cast<PngWriteBuffer*>(png_get_io_ptr(png));
  try {
    output->bytes.insert(output->bytes.end(), data, data + size);
  } catch (...) {
    png_error(png, "PNG test output allocation failed");
  }
}

void png_flush_vector(png_structp) {}

std::vector<std::uint8_t> make_pq_png() {
  PngWriteBuffer output;
  output.bytes.reserve(1024);
  png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, nullptr,
                                             nullptr, nullptr);
  require(png != nullptr, "cannot create the PNG test writer");
  png_infop info = png_create_info_struct(png);
  if (info == nullptr) {
    png_destroy_write_struct(&png, nullptr);
    throw std::runtime_error("cannot create the PNG test info");
  }
  png_set_write_fn(png, &output, png_write_to_vector, png_flush_vector);
  png_set_IHDR(png, info, 1, 1, 8, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE,
               PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);

  // PNG cICP: Display P3 primaries, PQ transfer, RGB matrix, full range.
  png_byte cicp_data[4]{12, 16, 0, 1};
  png_unknown_chunk cicp{};
  std::memcpy(cicp.name, "cICP", 4);
  cicp.data = cicp_data;
  cicp.size = sizeof(cicp_data);
  cicp.location = PNG_HAVE_IHDR;
  const png_byte cicp_name[4]{'c', 'I', 'C', 'P'};
  png_set_keep_unknown_chunks(png, PNG_HANDLE_CHUNK_ALWAYS, cicp_name, 1);
  png_set_unknown_chunks(png, info, &cicp, 1);
  png_write_info(png, info);
  png_byte row[3]{128, 128, 128};
  png_write_row(png, row);
  png_write_end(png, info);
  png_destroy_write_struct(&png, &info);
  return output.bytes;
}

void check_png_cicp_headroom() {
  const auto path = hyperdr::test::temporary_directory() /
                    "hyperdr-codec-cicp-pq.png";
  try {
    hyperdr::write_binary_file_atomic(path, make_pq_png(), true);
    const auto decoded = hyperdr::decode_image(path);
    require_declared_headroom(
        decoded, 10000.0F / hyperdr::kReferenceWhiteNits,
        "PQ PNG did not preserve cICP headroom");
    std::filesystem::remove(path);
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

hyperdr::DecodedImage decode_encoded_input(const std::vector<std::uint8_t>& bytes,
                                           const char* label,
                                           const char* extension = ".heic",
                                           const hyperdr::RawDecodeOptions& options = {}) {
  const auto path = hyperdr::test::temporary_directory() /
      (std::string("hyperdr-codec-input-") + label + extension);
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    auto decoded = hyperdr::decode_image(path, options);
    std::filesystem::remove(path);
    return decoded;
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

hyperdr::DecodedImage decode_gain_map_jpeg_input(const std::vector<std::uint8_t>& bytes) {
  const auto path =
      hyperdr::test::temporary_directory() / "hyperdr-codec-input-ultrahdr.jpg";
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
// Sony's HEIF stills are Main 4:2:2 10 HLG. Decoding those needs 4:2:2 chroma
// upsampling *and* an HEVC decoder that implements the range extensions,
// neither of which any other test touches. The fixture is therefore
// built here through VT's native Main42210 profile.

// Required native VT 4:2:2 fixture. Failure is a failure, never a skip.
std::vector<std::uint8_t> encode_hlg_422(const hyperdr::FloatImage& linear) {
  return heif_fixture::hlg422(linear);
}

// Proves the fixture really is 4:2:2 before its decode is used as evidence:
// the hvcC and the decoded picture both say so, where the conversion to RGB
// would otherwise hide the chroma format.
void require_chroma_422(const std::vector<std::uint8_t>& bytes) {
  const auto file = hyperdr::read_heif(bytes);
  const auto plan = file.resolve_image();
  require(plan.config.chroma_format == 2 && plan.config.bit_depth == 10,
          "the 4:2:2 fixture's hvcC is not 4:2:2 10-bit");
  unsigned pictures = 0;
  heif_native::for_each_picture(file, plan, [&](auto, auto, const heif_native::Picture& picture) {
    ++pictures;
    if (picture.chroma_format != 2) {
      throw std::runtime_error("the 4:2:2 fixture was not decoded as 4:2:2 (chroma=" +
                               std::to_string(picture.chroma_format) + ")");
    }
    require(picture.bit_depth == 10, "the 4:2:2 fixture is not 10-bit");
  });
  require(pictures > 0, "the 4:2:2 fixture decoded no pictures");
}

// An input's declared headroom, and the preview divisor that follows from it.
//
// `bytes` must be a gain-map file, so that the same pixels can be read both as
// HDR and -- through `ignore_embedded_gain_map` -- as the SDR base underneath.
// That is the sharpest available test of the gate: one file, two readings, and
// only the HDR one may be scaled.
void check_input_headroom(const std::vector<std::uint8_t>& bytes, const char* label,
                          const char* extension) {
  const auto path = hyperdr::test::temporary_directory() /
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

// Decodes the primary image with VideoToolbox and checks CICP plus non-inverted
// channel order at a bright sample. This is the regression the 8-bit default
// path was missing: a file can be structurally perfect and still carry an
// undecodable bitstream (for example a single-slice NAL the decoder refuses).
void decode_and_check(const std::vector<std::uint8_t>& bytes, std::uint32_t width, std::uint32_t height) {
  const auto file = hyperdr::read_heif(bytes);
  const auto plan = file.resolve_image();
  require(plan.color && plan.color->primaries == 12 && plan.color->transfer == 13 &&
              plan.color->matrix == 1 && plan.color->full_range && !plan.icc.empty(),
          "primary image has incorrect Display P3 CICP");
  require(plan.width == width && plan.height == height,
          "decoded primary image has wrong dimensions");
  const bool wide = plan.config.bit_depth > 8;
  // The normalized float is an integer code over the full-range maximum.
  const float maximum = wide ? 1023.F : 255.F;
  const auto code = [&](std::uint32_t x, std::uint32_t y) {
    const auto rgb = heif_native::encoded_rgb(file, plan, x, y);
    return std::array<int, 3>{int(std::lround(rgb[0] * maximum)), int(std::lround(rgb[1] * maximum)),
                              int(std::lround(rgb[2] * maximum))};
  };
  const auto bright = code(width - 2, height / 2);
  // At the almost-white sample the original channel separation can be less
  // than one code. Lossy VT quantisation may reverse it by two codes.
  const int slack = wide ? 2 : 0;
  const bool ordered = bright[0] + slack >= bright[1] && bright[1] + slack >= bright[2];
  const auto middle = code(width / 3, height / 2);
  const bool distinct = middle[0] > middle[1] && middle[1] > middle[2];
  require(ordered && distinct, "primary image color-channel round trip failed");
}

void check_gain_decode(const std::vector<std::uint8_t>& bytes,
                       const hyperdr::FloatImage* expected = nullptr) {
  const auto file = hyperdr::read_heif(bytes);
  const auto gain = file.resolve_gain_map();
  require(gain.has_value(), "cannot resolve the Gain Map");
  const auto& plan = gain->gain;
  require(plan.color && plan.color->primaries == 2 && plan.color->transfer == 2 &&
              plan.color->matrix == 1 && plan.color->full_range,
          "Gain Map nclx is not 2/2/1/full");
  require(plan.config.bit_depth == 8 && plan.config.chroma_format == 1,
          "Gain Map is not 8-bit 4:2:0");
  const int width = int(plan.width), height = int(plan.height);
  require(width > 0 && height > 0, "invalid Gain Map dimensions");
  if (expected) {
    require(expected->channels == 1 && expected->width == static_cast<std::uint32_t>(width) &&
                expected->height == static_cast<std::uint32_t>(height),
            "Gain Map probe has unexpected dimensions");
  }
  int minimum = 255;
  int maximum = 0;
  std::uint64_t total_code_error = 0;
  int maximum_code_error = 0;
  heif_native::for_each_picture(file, plan, [&](std::uint32_t x0, std::uint32_t y0,
                                                const heif_native::Picture& picture) {
    require(picture.bit_depth == 8 && picture.chroma_format == 1, "Gain Map picture is not 8-bit 4:2:0");
    for (std::uint32_t py = 0; py < picture.height && y0 + py < plan.height; ++py) {
      for (std::uint32_t px = 0; px < picture.width && x0 + px < plan.width; ++px) {
        const int actual = int(picture.luma_at(px, py));
        minimum = std::min(minimum, actual);
        maximum = std::max(maximum, actual);
        if (expected) {
          const auto wanted = static_cast<int>(std::lround(
              std::clamp(expected->at(x0 + px, y0 + py, 0), 0.0F, 1.0F) * 255.0F));
          const int code_error = std::abs(actual - wanted);
          total_code_error += code_error;
          maximum_code_error = std::max(maximum_code_error, code_error);
        }
      }
    }
    for (std::uint32_t cy = 0; cy < picture.chroma_height(); cy += std::max(1U, picture.chroma_height() / 32)) {
      for (std::uint32_t cx = 0; cx < picture.chroma_width(); cx += std::max(1U, picture.chroma_width() / 32)) {
        require(std::abs(int(picture.cb_at(cx, cy)) - 128) <= 3 &&
                    std::abs(int(picture.cr_at(cx, cy)) - 128) <= 3,
                "Gain Map chroma is not neutral");
      }
    }
  });
  if (expected) {
    const double mean_code_error = static_cast<double>(total_code_error) /
                                   (static_cast<double>(width) * height);
    std::cout << "Q95 Gain Map code error: mean " << mean_code_error
              << ", maximum " << maximum_code_error << '\n';
    require(mean_code_error <= 0.5 && maximum_code_error <= 3,
            "Q95 Gain Map changed the gain codes too much");
  }
  require(minimum <= 16 && maximum >= 239,
          "Gain Map does not retain full-range endpoints");
}
void check_semantic_rejections(const std::vector<std::uint8_t>& bytes) {
  const auto references = hyperdr::find_tmap_references(bytes);
  // The tmap item's dimg now claims three targets where two are listed.
  bool changed = false;
  const auto broken_dimg = heif_fixture::edit(bytes, [&](auto& meta) {
    for (auto& box : meta) {
      if (box.type != "iref") continue;
      heif_fixture::children(box, 4, [&](auto& refs) {
        for (auto& ref : refs) {
          if (ref.type == "dimg" && heif_fixture::get(ref.data, 0, 2) == references.tmap_id) {
            heif_fixture::put(ref.data, 2, 3, 2);
            changed = true;
          }
        }
      });
    }
  });
  require(changed && !hyperdr::inspect_heif(broken_dimg).structurally_valid,
          "grid dimg masked a broken tmap dimg");

  // The altr group takes an item's ID.
  changed = false;
  const auto colliding_group = heif_fixture::edit(bytes, [&](auto& meta) {
    for (auto& box : meta) {
      if (box.type != "grpl") continue;
      heif_fixture::children(box, 0, [&](auto& groups) {
        for (auto& group : groups) {
          if (group.type == "altr") {
            heif_fixture::put(group.data, 4, references.gain_id, 4);
            changed = true;
          }
        }
      });
    }
  });
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
  const auto temp_heic = hyperdr::test::temporary_directory() / "hyperdr-codec-test.heic";
  const auto temp_tiff = hyperdr::test::temporary_directory() / "hyperdr-codec-test.tiff";
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
  const auto temp_heic = hyperdr::test::temporary_directory() / "hyperdr-display-curve-test.heic";
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
  const auto directory = hyperdr::test::temporary_directory();
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

// A camera HLG photograph converted to both gain-map formats has to decode back
// to itself. The fixture is the shape that exposed the failures: a 4:2:2 HLG
// frame wide enough that its full-resolution gain map needs a grid, shadows
// below sRGB code 10, highlight bars one to three pixels wide, and a saturated
// highlight. Before the fix the highlights came back about a fifth darker (a
// cell-averaged map), saturated colour came back desaturated (a gain-map base
// gamut-fitted in SDR), and every Adaptive HEIC shadow under code 10 decoded as
// black (a zero slope in the base's ICC toe).
hyperdr::FloatImage make_camera_hdr(std::uint32_t width, std::uint32_t height) {
  const float peak = 1000.0F / hyperdr::kReferenceWhiteNits;
  hyperdr::FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const float t = static_cast<float>(x % 800) / 799.0F;
      std::array<float, 3> rgb{};
      if (x < 800) {
        const float v = 0.0003F + 0.02F * t;
        rgb = {v, v * 0.9F, v * 0.8F};
      } else if (x < 1600) {
        const float v = 0.05F + 0.85F * t;
        rgb = {v, v * (0.7F + 0.3F * y / height), v * 0.5F};
      } else if (x < 2400) {
        const bool bar = (x / 3U) % 2U == 0U;
        const float v = bar ? peak * 0.98F : 0.05F;
        rgb = {v, v, v};
      } else if (x < 2800) {
        rgb = {3.0F, 0.6F, 0.25F};
      } else {
        const float v = 1.0F + (peak - 1.0F) * t * 2.0F;
        rgb = {std::min(v, peak), std::min(v, peak) * 0.95F, std::min(v, peak) * 0.9F};
      }
      for (unsigned c = 0; c < 3; ++c) image.at(x, y, c) = rgb[c];
    }
  }
  return image;
}

float region_mean_luminance(const hyperdr::FloatImage& image, std::uint32_t x0,
                            std::uint32_t x1) {
  double total = 0.0;
  for (std::uint32_t y = 0; y < image.height; ++y) {
    for (std::uint32_t x = x0; x < x1; ++x) {
      total += hyperdr::p3_luminance(image.at(x, y, 0), image.at(x, y, 1), image.at(x, y, 2));
    }
  }
  return static_cast<float>(total / (static_cast<double>(x1 - x0) * image.height));
}

void check_hdr_source_gain_maps(const hyperdr::PhotoMetadata& metadata) {
  const auto hlg = encode_hlg_422(make_camera_hdr(3200, 48));
  require(!hlg.empty(), "VideoToolbox cannot produce the 4:2:2 HLG camera fixture");
  const auto source = decode_encoded_input(hlg, "camera-hlg");
  require(source.domain == hyperdr::InputDomain::kDisplayReferredHdr,
          "the HLG fixture must decode as an HDR source");

  hyperdr::RenderOptions identity;
  identity.auto_headroom = false;
  identity.headroom_stops = 3.0F;
  identity.look.headroom_max_stops = 3.0F;
  identity.look.shoulder_start = 0.25F;
  identity.look.contrast = 1.0F;
  identity.look.vibrance = 0.0F;
  auto photo = hyperdr::render_renditions(source.linear_p3, identity, source.capture,
                                          source.describe_input(),
                                          hyperdr::RenderTarget::Hdr);
  require(photo.hdr_is_source, "an HLG photograph must be packaged as its own HDR");
  const auto gain = hyperdr::gain_map_from_renditions(std::move(photo));
  require(gain.gain_map.width == 3200 && gain.gain_map.height == 48,
          "an HDR source's gain map must be full resolution");

  const auto check = [&](const hyperdr::DecodedImage& decoded, const char* label,
                         double mean_limit, double highlight_limit) {
    const auto fidelity = hyperdr::measure_hdr_fidelity(source.linear_p3, decoded.linear_p3);
    std::cout << label << ": delta E ITP mean " << fidelity.delta_e_itp_mean << ", p99 "
              << fidelity.delta_e_itp_p99 << ", highlights "
              << fidelity.band_delta_e_itp_mean[2] << ", peak " << fidelity.candidate_peak
              << " / " << fidelity.reference_peak << '\n';
    require(fidelity.delta_e_itp_mean < mean_limit,
            (std::string(label) + ": the HDR source did not survive its gain map").c_str());
    require(fidelity.band_delta_e_itp_mean[2] < highlight_limit,
            (std::string(label) + ": highlights did not survive their gain map").c_str());
    require(std::abs(fidelity.candidate_peak / fidelity.reference_peak - 1.0F) < 0.02F,
            (std::string(label) + ": the peak was not restored").c_str());
    const float shadows = region_mean_luminance(decoded.linear_p3, 0, 800) /
                          region_mean_luminance(source.linear_p3, 0, 800);
    require(shadows > 0.9F && shadows < 1.1F,
            (std::string(label) + ": shadows under sRGB code 10 were lost").c_str());
    const float bars = region_mean_luminance(decoded.linear_p3, 1600, 2400) /
                       region_mean_luminance(source.linear_p3, 1600, 2400);
    require(bars > 0.97F && bars < 1.03F,
            (std::string(label) + ": pixel-wide highlights lost brightness").c_str());
    const auto red = decoded.linear_p3.at(2600, 24, 0) /
                     std::max(decoded.linear_p3.at(2600, 24, 1), 1.0e-6F);
    const auto red_source = source.linear_p3.at(2600, 24, 0) /
                            std::max(source.linear_p3.at(2600, 24, 1), 1.0e-6F);
    require(std::abs(red / red_source - 1.0F) < 0.05F,
            (std::string(label) + ": a saturated highlight lost its colour").c_str());
  };

  const auto adaptive = hyperdr::encode_adaptive_heic(gain, metadata, 95, 10);
  check_structure(adaptive, "HDR-source adaptive");
  require_hevc_profiles(adaptive, true, true);
  hyperdr::verify_heic_decodable(adaptive);
  check(decode_encoded_input(adaptive, "hdr-source-adaptive"), "HLG source to Adaptive HEIC",
        1.5, 3.0);

  const auto gain_jpeg = hyperdr::encode_gain_map_jpeg(gain, metadata, 95);
  hyperdr::verify_gain_map_jpeg(gain_jpeg);
  check(decode_gain_map_jpeg_input(gain_jpeg), "HLG source to gain-map JPEG", 2.5, 3.0);
}

void check_rgb_gain_map_jpeg(const hyperdr::PhotoMetadata& metadata) {
  hyperdr::PhotoRenditions photo;
  photo.sdr = hyperdr::FloatImage(64, 32, 3);
  photo.hdr = hyperdr::FloatImage(64, 32, 3);
  photo.stats.headroom_stops = 2;
  photo.stats.headroom_linear = 4;
  for (unsigned y = 0; y < 32; ++y) for (unsigned x = 0; x < 64; ++x) {
    const std::array<float, 3> base{.5F, .4F, .2F};
    const std::array<float, 3> target{x < 32 ? 2.0F : .25F, .8F, .05F};
    for (unsigned c = 0; c < 3; ++c) {
      photo.sdr.at(x, y, c) = base[c];
      photo.hdr.at(x, y, c) = target[c];
    }
  }
  const auto packed = hyperdr::gain_map_from_renditions(photo,
      hyperdr::GainMapWriterProfile::iso_generic);
  const auto bytes = hyperdr::encode_gain_map_jpeg(packed, metadata, 95);
  hyperdr::verify_gain_map_jpeg(bytes);
  const auto decoded = decode_gain_map_jpeg_input(bytes);
  const float measured_peak = std::max(1.0F,
      *std::max_element(decoded.linear_p3.pixels.begin(), decoded.linear_p3.pixels.end()));
  require(decoded.domain == hyperdr::InputDomain::kDualRendition &&
              decoded.authored_sdr.has_value() && decoded.gain_map.channels == 3 &&
              std::abs(decoded.hdr_headroom - measured_peak) < 1e-5F,
          "RGB JPEG must retain both renditions and its measured range");
  double error = 0;
  for (std::size_t i = 0; i < photo.hdr.pixels.size(); ++i) {
    const float expected = photo.hdr.pixels[i];
    const float delta = decoded.linear_p3.pixels[i] - expected;
    require(std::abs(delta) < .06F * std::max(expected, .1F),
        "RGB JPEG round trip must retain channel ratios and negative gains");
    error += delta * delta;
  }
  std::cout << "Graded RGB gain-map JPEG MSE: " << error / photo.hdr.pixels.size() << '\n';
}

void check_gain_map_jpeg_icc(const hyperdr::PhotoMetadata& metadata) {
  hyperdr::PhotoRenditions photo;
  photo.sdr = hyperdr::FloatImage(32, 32, 3);
  std::fill(photo.sdr.pixels.begin(), photo.sdr.pixels.end(), .2F);
  photo.hdr = photo.sdr;
  for (auto& value : photo.hdr.pixels) value *= 2;
  photo.stats.headroom_stops = 1;
  photo.stats.headroom_linear = 2;
  for (bool clamp : {false, true}) for (bool pair : {false, true}) {
    photo.clamp_srgb = clamp;
    auto bytes = hyperdr::encode_gain_map_jpeg(hyperdr::gain_map_from_renditions(photo,
        hyperdr::GainMapWriterProfile::iso_generic), metadata, 95);
    (void)pair;
    hyperdr::verify_gain_map_jpeg(bytes);
    constexpr std::string_view signature = "ICC_PROFILE";
    const auto marker = std::search(bytes.begin(), bytes.end(), signature.begin(), signature.end());
    require(marker != bytes.end(), "gain-map JPEG primary must carry an ICC profile");
    // APP2 identifier, terminator, sequence number and chunk count precede ICC.
    const auto start = marker + 14;
    const auto profile = cmsOpenProfileFromMem(&*start,
        static_cast<cmsUInt32Number>(bytes.end() - start));
    require(profile != nullptr, "gain-map JPEG ICC must be readable by a colour manager");
    const auto* red = static_cast<const cmsCIEXYZ*>(cmsReadTag(profile, cmsSigRedColorantTag));
    const auto* curve = static_cast<const cmsToneCurve*>(cmsReadTag(profile, cmsSigRedTRCTag));
    const bool valid = red && curve && std::abs(red->X - .5151) < .001 &&
        std::abs(cmsEvalToneCurveFloat(curve, .02F) - hyperdr::srgb_eotf(.02F)) < 1e-5F;
    cmsCloseProfile(profile);
    require(valid, "gain-map JPEG pixels require Display P3 primaries and an sRGB toe, including gamut clamp");
    // Hide only the identifier, preserving JPEG lengths and MPF offsets.
    *marker = 'X';
    bool rejected = false;
    try { hyperdr::verify_gain_map_jpeg(bytes); }
    catch (const std::runtime_error& error) {
      rejected = std::string_view(error.what()).find("no primary ICC profile") != std::string_view::npos;
    }
    require(rejected, "gain-map JPEG verification must reject an empty ICC block even when its pointer exists");
  }
}

std::vector<std::uint8_t> encode_icc_only_heic() {
  namespace h=hyperdr::codec::hevc;
  h::EncodeParams params;params.color={2,2,1};
  auto sequence=h::encode(1,[](auto,h::YuvTile& tile){h::rgb_tile(h::tile_grid(4,4),0,
      [](auto,auto,auto count,float* v){for(unsigned i=0;i<count;++i){v[3*i]=48.F/255;v[3*i+1]=96.F/255;v[3*i+2]=144.F/255;}},1,false,tile);},params);
  hyperdr::HeifEncodedImage image{sequence,4,4,{},std::nullopt,{}};
  auto bytes=hyperdr::write_heif(image);
  cmsHPROFILE profile=cmsCreate_sRGBProfile();
  require(profile!=nullptr,"create ICC-only fixture profile");cmsUInt32Number size=0;
  const bool sized=cmsSaveProfileToMem(profile,nullptr,&size)!=0;
  std::vector<std::uint8_t> icc(size);
  const bool saved=sized&&cmsSaveProfileToMem(profile,icc.data(),&size);cmsCloseProfile(profile);
  require(saved,"serialize ICC-only fixture profile");icc.resize(size);
  return heif_fixture::edit(bytes,[&](auto& meta){heif_fixture::properties(meta,[&](auto& prop){
    if(prop.type=="colr"){prop.data={'p','r','o','f'};prop.data.insert(prop.data.end(),icc.begin(),icc.end());}
  });});
}

void check_icc_only_heic() {
  const auto bytes = encode_icc_only_heic();
  {
    const auto file = hyperdr::read_heif(bytes);
    const auto plan = file.resolve_image();
    require(!plan.icc.empty(), "ICC-only fixture lost its ICC profile");
    require(!plan.color, "ICC-only fixture unexpectedly contains nclx");
  }

  const auto path = hyperdr::test::temporary_directory() /
                    "hyperdr-codec-icc-only.heic";
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    const auto decoded = hyperdr::decode_image(path);
    require(decoded.linear_p3.width == 4 && decoded.linear_p3.height == 4,
            "ICC-only HEIC did not decode normally");
    bool rejected = false;
    try {
      hyperdr::verify_heic_decodable(path);
    } catch (const std::runtime_error& error) {
      rejected = std::string_view(error.what()).find(
                     "neither Adaptive HDR nor nclx-signalled PQ/HLG") !=
                 std::string_view::npos;
    }
    require(rejected, "ICC-only HEIC verification must fail cleanly without nclx");
    std::filesystem::remove(path);
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

void check_avif_gain_map(bool hdr_primary) {
  std::unique_ptr<avifImage, decltype(&avifImageDestroy)> image(
      avifImageCreate(8, 6, 8, AVIF_PIXEL_FORMAT_YUV400), &avifImageDestroy);
  require(image && avifImageAllocatePlanes(image.get(), AVIF_PLANES_YUV) == AVIF_RESULT_OK,
          "create AVIF primary fixture");
  image->yuvRange = AVIF_RANGE_FULL;
  image->colorPrimaries = hdr_primary ? AVIF_COLOR_PRIMARIES_BT2020
                                     : AVIF_COLOR_PRIMARIES_BT709;
  image->transferCharacteristics = hdr_primary ? AVIF_TRANSFER_CHARACTERISTICS_PQ
                                               : AVIF_TRANSFER_CHARACTERISTICS_SRGB;
  image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT709;
  for (unsigned y = 0; y < 6; ++y)
    std::memset(image->yuvPlanes[AVIF_CHAN_Y] + y * image->yuvRowBytes[AVIF_CHAN_Y],
                hdr_primary ? 180 : 220, 8);
  require(avifImageAllocatePlanes(image.get(), AVIF_PLANES_A) == AVIF_RESULT_OK,
          "allocate AVIF alpha fixture");
  for (unsigned y = 0; y < 6; ++y)
    std::memset(image->alphaPlane + y * image->alphaRowBytes, 255, 8);
  image->alphaPlane[0] = 0;
  image->transformFlags = AVIF_TRANSFORM_IROT;
  image->irot.angle = 1;

  image->gainMap = avifGainMapCreate();
  require(image->gainMap != nullptr, "create AVIF gain map");
  auto* map = image->gainMap;
  map->image = avifImageCreate(4, 3, 8, AVIF_PIXEL_FORMAT_YUV400);
  require(map->image && avifImageAllocatePlanes(map->image, AVIF_PLANES_YUV) == AVIF_RESULT_OK,
          "create AVIF gain pixels");
  for (unsigned y = 0; y < 3; ++y)
    std::memset(map->image->yuvPlanes[AVIF_CHAN_Y] + y * map->image->yuvRowBytes[AVIF_CHAN_Y],
                255, 4);
  map->image->yuvRange = AVIF_RANGE_FULL;
  map->image->colorPrimaries = AVIF_COLOR_PRIMARIES_UNSPECIFIED;
  map->image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED;
  map->image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT709;
  map->useBaseColorSpace = AVIF_TRUE;
  map->baseHdrHeadroom = hdr_primary ? avifUnsignedFraction{2, 1} : avifUnsignedFraction{0, 1};
  map->alternateHdrHeadroom = hdr_primary ? avifUnsignedFraction{0, 1} : avifUnsignedFraction{2, 1};
  for (unsigned c = 0; c < 3; ++c) {
    map->gainMapMin[c] = {0, 1}; map->gainMapMax[c] = {2, 1};
    map->gainMapGamma[c] = {1, 1};
    map->baseOffset[c] = {0, 1}; map->alternateOffset[c] = {0, 1};
  }
  map->altDepth = 8;
  map->altPlaneCount = 3;
  map->altColorPrimaries = hdr_primary ? AVIF_COLOR_PRIMARIES_BT709
                                      : AVIF_COLOR_PRIMARIES_BT2020;
  map->altTransferCharacteristics = hdr_primary ? AVIF_TRANSFER_CHARACTERISTICS_SRGB
                                               : AVIF_TRANSFER_CHARACTERISTICS_PQ;
  map->altMatrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT709;
  map->altYUVRange = AVIF_RANGE_FULL;

  if (hdr_primary) {
    cmsHPROFILE profile = cmsCreate_sRGBProfile();
    require(profile != nullptr, "create AVIF ICC fixture");
    cmsUInt32Number size = 0;
    require(cmsSaveProfileToMem(profile, nullptr, &size) && size > 0,
            "size AVIF ICC fixture");
    std::vector<std::uint8_t> icc(size);
    const bool saved = cmsSaveProfileToMem(profile, icc.data(), &size) != 0;
    cmsCloseProfile(profile);
    require(saved && avifImageSetProfileICC(image.get(), icc.data(), size) == AVIF_RESULT_OK,
            "attach ICC beside PQ CICP");
  }

  std::unique_ptr<avifEncoder, decltype(&avifEncoderDestroy)> encoder(
      avifEncoderCreate(), &avifEncoderDestroy);
  require(encoder != nullptr, "create AVIF encoder");
  avifRWData encoded = AVIF_DATA_EMPTY;
  const auto status = avifEncoderWrite(encoder.get(), image.get(), &encoded);
  require(status == AVIF_RESULT_OK, "encode AVIF gain-map fixture");
  std::vector<std::uint8_t> bytes(encoded.data, encoded.data + encoded.size);
  avifRWDataFree(&encoded);
  if (hdr_primary) {
    std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> inspect(
        avifDecoderCreate(), &avifDecoderDestroy);
    require(inspect && avifDecoderSetIOMemory(inspect.get(), bytes.data(), bytes.size()) == AVIF_RESULT_OK &&
                avifDecoderParse(inspect.get()) == AVIF_RESULT_OK && inspect->image &&
                inspect->image->icc.size > 0 &&
                inspect->image->transferCharacteristics == AVIF_TRANSFER_CHARACTERISTICS_PQ,
            "AVIF fixture must store ICC and PQ CICP together");
  }
  const auto path = hyperdr::test::temporary_directory() /
      (hdr_primary ? "hyperdr-gain-hdr-primary.avif" : "hyperdr-gain-sdr-primary.avif");
  hyperdr::write_binary_file_atomic(path, bytes, true);
  try {
    const auto decoded = hyperdr::decode_image(path);
    if (decoded.domain != hyperdr::InputDomain::kDualRendition ||
        !decoded.authored_sdr || decoded.hdr_headroom <= 1.0F || decoded.decode.degraded)
      std::cerr << "AVIF gain fixture " << (hdr_primary ? "HDR" : "SDR")
                << " primary domain=" << hyperdr::input_domain_name(decoded.domain)
                << " headroom=" << decoded.hdr_headroom << " degraded=" << decoded.decode.degraded
                << (decoded.decode.degradation_reasons.empty() ? "" : decoded.decode.degradation_reasons.front())
                << '\n';
    require(decoded.domain == hyperdr::InputDomain::kDualRendition &&
                decoded.authored_sdr.has_value() && decoded.gain_map.channels == 1 &&
                decoded.hdr_headroom > 1.0F && !decoded.decode.degraded,
            "AVIF gain map must preserve SDR and HDR in either direction");
    require(decoded.linear_p3.width == 6 && decoded.linear_p3.height == 8 &&
                decoded.linear_p3.width == decoded.authored_sdr->width &&
                decoded.linear_p3.height == decoded.authored_sdr->height &&
                decoded.linear_p3.at(3, 2, 0) > decoded.authored_sdr->at(3, 2, 0),
            "AVIF gain map must rotate and align both authored renditions");
    require(decoded.linear_p3.at(0, 7, 0) < decoded.linear_p3.at(5, 0, 0) * .1F &&
                decoded.authored_sdr->at(0, 7, 0) <
                    decoded.authored_sdr->at(5, 0, 0) * .1F,
            "AVIF alpha must composite both rotated renditions");
    if (hdr_primary)
      require(decoded.hdr_headroom > 1.0F,
              "PQ CICP must survive an accompanying SDR ICC profile");
    hyperdr::RawDecodeOptions preview_options;
    preview_options.preview_max_edge = 4;
    const auto preview = hyperdr::decode_image(path, preview_options);
    require(preview.domain == hyperdr::InputDomain::kDualRendition &&
                preview.authored_sdr.has_value() &&
                preview.linear_p3.width == 3 && preview.linear_p3.height == 4 &&
                preview.authored_sdr->width == 3 && preview.authored_sdr->height == 4 &&
                preview.linear_p3.at(1, 1, 0) > preview.authored_sdr->at(1, 1, 0),
            "AVIF preview must reduce and rotate both aligned renditions");
    std::filesystem::remove(path);
  } catch (...) {
    std::filesystem::remove(path);
    throw;
  }
}

void require_avif_content_light(const std::vector<std::uint8_t>& bytes,
                                const hyperdr::FloatImage& source) {
  std::unique_ptr<avifDecoder, decltype(&avifDecoderDestroy)> decoder(
      avifDecoderCreate(), &avifDecoderDestroy);
  require(decoder != nullptr, "cannot allocate the AVIF metadata decoder");
  require(avifDecoderSetIOMemory(decoder.get(), bytes.data(), bytes.size()) ==
              AVIF_RESULT_OK &&
              avifDecoderParse(decoder.get()) == AVIF_RESULT_OK &&
              avifDecoderNextImage(decoder.get()) == AVIF_RESULT_OK,
          "cannot read AVIF content-light metadata");
  const auto expected = expected_content_light(source);
  require(decoder->image != nullptr &&
              decoder->image->clli.maxCLL == expected[0] &&
              decoder->image->clli.maxPALL == expected[1],
          "AVIF CLLI does not use maxRGB for MaxCLL and MaxPALL");
}

void check_gain_map_jpeg_pair(const hyperdr::PhotoMetadata& metadata) {
  hyperdr::PhotoRenditions photo;
  // Odd dimensions exercise half-float packed stride and JPEG edge padding.
  photo.sdr = hyperdr::FloatImage(65, 33, 3);
  photo.hdr = hyperdr::FloatImage(65, 33, 3);
  photo.stats.headroom_stops = 2;
  photo.stats.headroom_linear = 4;
  for (unsigned y = 0; y < 33; ++y) for (unsigned x = 0; x < 65; ++x) {
    const std::array<float, 3> base{.5F, .4F, .2F};
    // Keep this pair inside both P3 and sRGB: XMP gain applies in base gamut.
    const std::array<float, 3> target{x < 32 ? 2.0F : .25F, .8F, .15F};
    for (unsigned c = 0; c < 3; ++c) {
      photo.sdr.at(x, y, c) = base[c];
      photo.hdr.at(x, y, c) = target[c];
    }
  }
  const auto check_hdr = [&](const std::vector<std::uint8_t>& bytes) {
    hyperdr::verify_gain_map_jpeg(bytes);
    const auto parsed = hyperdr::parse_gain_map_jpeg(bytes);
    require(hyperdr::rational_value(hyperdr::gain_map_channel(parsed.metadata, 0).gain_min) < 0, "ISO JPEG must support signed RGB gain");
    require(std::abs(hyperdr::rational_value(parsed.metadata.alternate_headroom) - 2) < .001F,
        "ISO JPEG capacity must describe the rendered peak");
    const auto decoded = decode_gain_map_jpeg_input(bytes);
    const float measured_peak = std::max(1.0F,
        *std::max_element(decoded.linear_p3.pixels.begin(), decoded.linear_p3.pixels.end()));
    require(decoded.domain == hyperdr::InputDomain::kDualRendition &&
                decoded.authored_sdr.has_value() &&
                std::abs(decoded.hdr_headroom - measured_peak) < 1e-5F,
            "ISO JPEG must retain both authored renditions and measured headroom");
    require(decoded.metadata.model == metadata.model, "ISO JPEG must preserve EXIF");
    double error = 0;
    for (std::size_t i = 0; i < photo.hdr.pixels.size(); ++i) {
      const float expected = photo.hdr.pixels[i];
      const float delta = decoded.linear_p3.pixels[i] - expected;
      if (std::abs(delta) >= .08F * std::max(expected, .1F)) {
        std::cerr << "ISO JPEG mismatch sample " << i << ": got " << decoded.linear_p3.pixels[i]
                  << " expected " << expected << '\n';
      }
      require(std::abs(delta) < .08F * std::max(expected, .1F),
          "ISO JPEG must reconstruct independent channel ratios");
      error += delta * delta;
    }
    std::cout << "ISO JPEG RGB gain-map MSE: " << error / photo.hdr.pixels.size() << '\n';
  };
  const auto packed = hyperdr::gain_map_from_renditions(photo, hyperdr::GainMapWriterProfile::iso_generic);
  check_hdr(hyperdr::encode_gain_map_jpeg(packed, metadata, 90));
  // Zero headroom is a valid SDR-compatible ISO gain-map JPEG.
  photo.hdr = photo.sdr;
  photo.stats.headroom_stops = 0;
  hyperdr::verify_gain_map_jpeg(hyperdr::encode_gain_map_jpeg(
      hyperdr::gain_map_from_renditions(photo, hyperdr::GainMapWriterProfile::iso_generic), metadata, 90));
}

}  // namespace

// Apple's pre-ISO HDR photo: an SDR primary, an 8-bit monochrome auxiliary
// image of type urn:com:apple:photo:2020:aux:hdrgainmap, and the headroom in
// MakerNote tags 33 and 48. Our writer only writes ISO tone-mapped pairs, so
// the gain item is written as the ISO auxiliary and then given the auxC URN and
// auxl reference Apple writes, with the tmap item and its group removed.
std::vector<std::uint8_t> encode_apple_legacy_heic(bool with_makernote, bool midtone = false) {
  namespace h=hyperdr::codec::hevc;
  constexpr int kSize=16;const auto grid=h::tile_grid(kSize,kSize);
  h::EncodeParams params;params.quality=100;params.color={12,13,1};
  auto primary=h::encode(1,[&](auto,h::YuvTile& tile){h::rgb_tile(grid,0,
      [](auto,auto,auto n,float* v){std::fill_n(v,n*3,128.F/255);},1,false,tile);},params);
  params.color={2,2,1};
  auto gain=h::encode(1,[&](auto,h::YuvTile& tile){h::luma_tile(grid,0,
      [&](auto,auto x0,auto n,float* v){for(unsigned i=0;i<n;++i)v[i]=midtone?128.F/255:(x0+i<kSize/2?1.F:0.F);},tile);},params);
  auto icc=hyperdr::codec::display_p3_profile();
  hyperdr::HeifEncodedImage base_image{primary,kSize,kSize,{},std::nullopt,icc},gain_image{gain,kSize,kSize,{2,2,1,true},std::nullopt,{}};
  hyperdr::HeifWriteOptions options;options.gain_metadata=hyperdr::GainMapMetadata{};
  if (with_makernote) {
    // The Exif fixture from exif_test: tags 33 = 3/2 and 48 = 0 declare 3 stops.
    std::vector<std::uint8_t> tiff(104, 0);
    const auto le16 = [&](std::size_t at, std::uint16_t v) {
      tiff[at] = static_cast<std::uint8_t>(v); tiff[at + 1] = static_cast<std::uint8_t>(v >> 8);
    };
    const auto le32 = [&](std::size_t at, std::uint32_t v) {
      for (unsigned i = 0; i < 4; ++i) tiff[at + i] = static_cast<std::uint8_t>(v >> (8 * i));
    };
    const auto be16 = [&](std::size_t at, std::uint16_t v) {
      tiff[at] = static_cast<std::uint8_t>(v >> 8); tiff[at + 1] = static_cast<std::uint8_t>(v);
    };
    const auto be32 = [&](std::size_t at, std::uint32_t v) {
      for (unsigned i = 0; i < 4; ++i) tiff[at + i] = static_cast<std::uint8_t>(v >> (24 - 8 * i));
    };
    tiff[0] = tiff[1] = 'I';
    le16(2, 42); le32(4, 8);
    le16(8, 1); le16(10, 0x8769); le16(12, 4); le32(14, 1); le32(18, 26);
    le16(26, 1); le16(28, 0x927C); le16(30, 7); le32(32, 60); le32(36, 44);
    tiff[54] = tiff[55] = 'M'; be16(56, 2);
    be16(58, 0x21); be16(60, 10); be32(62, 1); be32(66, 38);
    be16(70, 0x30); be16(72, 10); be32(74, 1); be32(78, 46);
    be32(82, 3); be32(86, 2); be32(90, 0); be32(94, 1);
    options.exif=std::move(tiff);
  }
  auto bytes=hyperdr::write_heif(base_image,&gain_image,options);
  bytes=heif_fixture::edit(bytes,[](auto& meta){
    heif_fixture::properties(meta,[](auto& prop){if(prop.type=="auxC"){
      const std::string urn="urn:com:apple:photo:2020:aux:hdrgainmap";
      prop.data.assign(4,0);prop.data.insert(prop.data.end(),urn.begin(),urn.end());prop.data.push_back(0);
    }});
    for(auto& box:meta){
      if(box.type=="grpl")box.type="free";
      if(box.type=="iinf")heif_fixture::children(box,8,[](auto& entries){for(auto& e:entries)
        if(e.type=="infe"&&e.data.size()>=12&&std::string(e.data.begin()+8,e.data.begin()+12)=="tmap")
          std::copy_n("free",4,e.data.begin()+8);
      });
      if(box.type=="iref")heif_fixture::children(box,4,[](auto& refs){for(auto& r:refs)
        if(r.type=="dimg"&&heif_fixture::get(r.data,0,2)==5)r.type="free";
      });
    }
  });
  auto top=heif_fixture::parse(bytes);
  for(auto& box:top)if(box.type=="ftyp")for(std::size_t i=8;i+4<=box.data.size();i+=4)
    if(std::string(box.data.begin()+i,box.data.begin()+i+4)=="tmap")std::copy_n("mif1",4,box.data.begin()+i);
  return heif_fixture::serialize(top);
}

void check_apple_legacy_heic() {
  const auto path = hyperdr::test::temporary_directory() / "hyperdr-apple-legacy.heic";
  try {
    hyperdr::write_binary_file_atomic(path, encode_apple_legacy_heic(true), true);
    const auto decoded = hyperdr::decode_image(path);
    require(decoded.domain == hyperdr::InputDomain::kDualRendition &&
                decoded.authored_sdr.has_value() && !decoded.decode.degraded,
            "a legacy Apple gain map must decode as a dual rendition");
    // The MakerNote declares 8x; this grey base reaches only 8x its own level.
    const float measured = std::max(1.0F, *std::max_element(
        decoded.linear_p3.pixels.begin(), decoded.linear_p3.pixels.end()));
    require(std::abs(decoded.gain_map.alternate_headroom - 8.0F) < 1e-3F &&
                std::abs(decoded.hdr_headroom - measured) < 1e-5F &&
                decoded.hdr_headroom < 4.0F,
            "legacy Apple usable headroom must be the measured peak, not the MakerNote capacity");

    // A mid-code gain distinguishes Apple's power curve from BT.709 inverse OETF.
    const auto mid_bytes = encode_apple_legacy_heic(true, true);
    hyperdr::write_binary_file_atomic(path, mid_bytes, true);
    const auto mid = hyperdr::decode_image(path);
    const auto file = hyperdr::read_heif(mid_bytes);
    float code = -1;
    for (const auto& [id, item] : file.items) {
      if (file.auxiliary_type(id) != "urn:com:apple:photo:2020:aux:hdrgainmap") continue;
      const auto plan = file.resolve_image(id);
      hyperdr::codec::hevc::decode_item(plan.config, plan.tiles.size(),
          [&](std::size_t i) { const auto& e=plan.tiles[i].extents.front();return file.bytes.subspan(e.offset,e.length); },
          [&](auto, hyperdr::codec::hevc::DecodedPicture&& picture) {code=picture.luma_at(8,8)/255.F;});
    }
    require(code > .45F && code < .55F, "legacy mid-code fixture was not preserved");
    const float ratio = mid.linear_p3.at(8,8,0) / mid.authored_sdr->at(8,8,0);
    require(std::abs(ratio - (1 + 7 * std::pow(code,2.2F))) < 1e-5F,
            "legacy Apple gain must intentionally use code^2.2, not BT.709");

    hyperdr::write_binary_file_atomic(path, encode_apple_legacy_heic(false), true);
    const auto fallback = hyperdr::decode_image(path);
    const bool reported = !fallback.decode.degradation_reasons.empty() &&
        fallback.decode.degradation_reasons.front().rfind(
            "apple_legacy_gain_map_unusable_sdr_fallback:", 0) == 0;
    require(fallback.domain == hyperdr::InputDomain::kDisplayReferredSdr &&
                !fallback.authored_sdr && fallback.decode.degraded && reported,
            "a legacy Apple gain map without MakerNote headroom must fall back to degraded SDR");
    std::filesystem::remove(path);
  } catch (...) {
    std::error_code ignored;
    std::filesystem::remove(path, ignored);
    throw;
  }
}

int main() try {
  try {
    hyperdr::GainMapOptions options;
    options.auto_exposure = false;
    options.auto_headroom = false;
    options.headroom_stops = 3.0F;
    hyperdr::PhotoMetadata metadata;
    metadata.model = "ILCE-7RM5";
    metadata.lens = "Synthetic test lens";
    metadata.iso = 100;
    metadata.exposure_seconds = 1.0 / 125.0;
    metadata.aperture = 2.8;
    metadata.date_time = "2026:08:12 10:11:12";
    check_rgb_gain_map_jpeg(metadata);
    check_gain_map_jpeg_pair(metadata);
    check_gain_map_jpeg_icc(metadata);
    const auto caps=hyperdr::codec::hevc::encoder_caps();
    const bool have_hevc = caps.main8 && caps.main10;
    if (have_hevc) {
      check_icc_only_heic();
      check_apple_legacy_heic();
    }
    check_avif_gain_map(false);
    check_avif_gain_map(true);

    if (!have_hevc) {
      // The transitional macOS build intentionally has a decoder only. Keep
      // its JPEG/R and AVIF round trips active without generating HEVC fixtures.
      const auto small = make_synthetic(64, 32);
      const auto gain = hyperdr::make_gain_map(small, options);
      const auto expected = hyperdr::reconstruct_gain_map(
          gain.base_linear, gain.gain_map, gain.metadata, gain.headroom_stops);
      const auto jpeg = hyperdr::encode_gain_map_jpeg(gain, metadata, 90);
      hyperdr::verify_gain_map_jpeg(jpeg);
      require_linear_round_trip(decode_gain_map_jpeg_input(jpeg), expected,
                                "gain-map JPEG round trip changed brightness");
      for (const auto encoding : {hyperdr::HdrEncoding::AvifPq,
                                  hyperdr::HdrEncoding::AvifHlg}) {
        const auto bytes = hyperdr::encode_avif(hyperdr::renditions_from_gain_map(gain), metadata, 80, encoding);
        hyperdr::verify_avif_decodable(bytes);
        require_linear_round_trip(decode_encoded_input(bytes, "avif", ".avif"), expected,
                                  "AVIF round trip changed brightness");
      }
      check_png_cicp_headroom();
      std::cout << "codec round trips passed; HEVC fixtures skipped (no encoder)\n";
      return 0;
    }

    // Default 8-bit output through the grid path (wider than one 512 tile), with a
    // full decode and gain-map reconstruction regression, not just structure checks.
    const auto large = make_synthetic(2600, 1408);
    const auto large_gain = hyperdr::make_gain_map(large, options);
    const auto bytes8 = hyperdr::encode_adaptive_heic(large_gain, metadata, 90, 8);
    check_structure(bytes8, "8-bit grid");
    require_hevc_profiles(bytes8, false, true);
    decode_and_check(bytes8, 2600, 1408);
    check_gain_decode(bytes8);
    check_semantic_rejections(bytes8);
    hyperdr::verify_heic_decodable(bytes8);
    reconstruct_and_check(bytes8, "8-bit grid");
    display_curve_identity_check(bytes8, "8-bit grid");

    // Single-tile 8-bit output.
    const auto small = make_synthetic(64, 32);
    const auto small_gain = hyperdr::make_gain_map(small, options);

    // The name no longer decides which decoder reads a raster. A phone gallery
    // exports HEIC under a .jpg suffix routinely, and that file used to reach
    // the plain JPEG decoder and be rejected for a bad marker -- a true
    // statement about a file that was never a JPEG.
    {
      const auto heic = hyperdr::encode_adaptive_heic(small_gain, metadata, 90, 8);
      const auto truthful = decode_encoded_input(heic, "signature-heic", ".heic");
      for (const char* alias : {".jpg", ".png", ".avif"}) {
        const auto renamed = decode_encoded_input(heic, "signature-alias", alias);
        require(renamed.linear_p3.width == truthful.linear_p3.width &&
                    renamed.linear_p3.height == truthful.linear_p3.height,
                "a renamed HEIC did not decode to the same geometry");
        require(renamed.linear_p3.pixels == truthful.linear_p3.pixels,
                "a renamed HEIC did not decode to the same pixels");
      }

      const auto jpeg = hyperdr::encode_gain_map_jpeg(small_gain, metadata, 90);
      const auto jpeg_truthful = decode_encoded_input(jpeg, "signature-jpeg", ".jpg");
      const auto jpeg_renamed = decode_encoded_input(jpeg, "signature-jpeg", ".png");
      require(jpeg_renamed.linear_p3.pixels == jpeg_truthful.linear_p3.pixels,
              "a renamed gain-map JPEG did not decode to the same pixels");

      // A supported extension is not a promise. Refusing this by signature, and
      // saying so, beats a codec-level complaint about a missing marker.
      const std::vector<std::uint8_t> prose(64, std::uint8_t{'a'});
      bool refused = false;
      try {
        static_cast<void>(decode_encoded_input(prose, "signature-prose", ".jpg"));
      } catch (const hyperdr::DecodeFailed& error) {
        refused = std::string(error.what()).find("no supported signature") !=
                  std::string::npos;
      }
      require(refused, "a non-image named .jpg was not refused by signature");
      std::cout << "signature dispatch passed\n";
    }

    // JPEG and HEIC can both carry an Exif-only phone orientation. The pixels,
    // metadata and reported decode geometry must all become upright together;
    // otherwise an export is either sideways or rotated a second time by its
    // viewer. These exercise the real container decoders rather than only the
    // orientation pixel primitive.
    auto portrait_metadata = metadata;
    portrait_metadata.orientation = 6;
    hyperdr::RawDecodeOptions base_only;
    base_only.ignore_embedded_gain_map = true;
    const auto oriented_jpeg_bytes =
        hyperdr::encode_gain_map_jpeg(small_gain, portrait_metadata, 90);
    const auto oriented_jpeg_path = hyperdr::test::temporary_directory() /
                                    "hyperdr-codec-oriented-jpeg.jpg";
    hyperdr::write_binary_file_atomic(oriented_jpeg_path, oriented_jpeg_bytes,
                                      true);
    const auto oriented_jpeg =
        hyperdr::decode_image(oriented_jpeg_path, base_only);
    auto reduced_jpeg_options = base_only;
    reduced_jpeg_options.preview_max_edge = 8;
    const auto reduced_oriented_jpeg =
        hyperdr::decode_image(oriented_jpeg_path, reduced_jpeg_options);
    std::filesystem::remove(oriented_jpeg_path);
    require(reduced_oriented_jpeg.linear_p3.width == 4 &&
                reduced_oriented_jpeg.linear_p3.height == 8 &&
                reduced_oriented_jpeg.decode.sensor_width == 64 &&
                reduced_oriented_jpeg.decode.sensor_height == 32 &&
                reduced_oriented_jpeg.decode.target_width == 32 &&
                reduced_oriented_jpeg.decode.target_height == 64 &&
                reduced_oriented_jpeg.decode.decoded_width == 4 &&
                reduced_oriented_jpeg.decode.decoded_height == 8 &&
                !reduced_oriented_jpeg.decode.resolution_reduced &&
                reduced_oriented_jpeg.metadata.orientation == 1,
            "reduced JPEG lost upright original/target geometry or reported a degraded preview");
    require(oriented_jpeg.linear_p3.width == 32 &&
                oriented_jpeg.linear_p3.height == 64 &&
                oriented_jpeg.decode.target_width == 32 &&
                oriented_jpeg.decode.target_height == 64 &&
                oriented_jpeg.decode.decoded_width == 32 &&
                oriented_jpeg.decode.decoded_height == 64 &&
                oriented_jpeg.metadata.orientation == 1,
            "JPEG Exif orientation did not normalize pixels, geometry and metadata");

    // The writer normalises Exif orientation on output, so make an Exif-only
    // input fixture by changing that one TIFF value after encoding.
    // This mirrors phones whose pixels are landscape-stored without adding an
    // irot/imir property that would make the container authoritative.
    auto oriented_heic_bytes =
        hyperdr::encode_adaptive_heic(small_gain, metadata, 90, 8);
    const auto upright_exif = hyperdr::make_minimal_exif(metadata);
    const auto portrait_exif = hyperdr::make_minimal_exif(portrait_metadata);
    const auto exif_position = std::search(oriented_heic_bytes.begin(),
                                           oriented_heic_bytes.end(),
                                           upright_exif.begin(), upright_exif.end());
    require(exif_position != oriented_heic_bytes.end(),
            "encoded HEIC does not contain its Exif payload");
    std::vector<std::size_t> exif_differences;
    for (std::size_t index = 0; index < upright_exif.size(); ++index) {
      if (upright_exif[index] != portrait_exif[index]) {
        exif_differences.push_back(index);
      }
    }
    require(exif_differences.size() == 1,
            "orientation changed more than one Exif payload byte");
    *(exif_position + static_cast<std::ptrdiff_t>(exif_differences.front())) =
        portrait_exif[exif_differences.front()];
    const auto patched_orientation = hyperdr::read_exif_orientation(
        &*exif_position, upright_exif.size());
    require(patched_orientation && *patched_orientation == 6,
            "raw HEIC Exif patch did not produce orientation 6");
    {
      const auto file = hyperdr::read_heif(oriented_heic_bytes);
      const auto plan = file.resolve_image();
      require(plan.transforms.empty(),
              "Exif-only HEIC fixture unexpectedly has a container orientation");
      const auto exif = file.exif();
      require(!exif.empty(), "oriented HEIC fixture has no Exif item");
      const auto orientation =
          hyperdr::read_exif_orientation(exif.data(), exif.size());
      require(orientation && *orientation == 6,
              "oriented HEIC fixture lost its Exif orientation");
    }
    const auto oriented_heic = decode_encoded_input(oriented_heic_bytes,
                                                     "oriented-heic");
    require(oriented_heic.linear_p3.width == 32 &&
                oriented_heic.linear_p3.height == 64 &&
                oriented_heic.decode.target_width == 32 &&
                oriented_heic.decode.target_height == 64 &&
                oriented_heic.decode.decoded_width == 32 &&
                oriented_heic.decode.decoded_height == 64 &&
                oriented_heic.metadata.orientation == 1,
            "HEIC Exif orientation did not normalize pixels, geometry and metadata");

    const auto gain_jpeg = hyperdr::encode_gain_map_jpeg(small_gain, metadata, 90);
    require(gain_jpeg.size() > 512 && gain_jpeg[0] == 0xFF && gain_jpeg[1] == 0xD8,
            "gain-map JPEG output is not a JPEG stream");
    hyperdr::verify_gain_map_jpeg(gain_jpeg);
    const auto expected_gain_jpeg = hyperdr::reconstruct_gain_map(
        small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
        small_gain.headroom_stops);
    const auto decoded_gain_jpeg = decode_gain_map_jpeg_input(gain_jpeg);
    require(decoded_gain_jpeg.metadata.model == metadata.model &&
                decoded_gain_jpeg.metadata.lens == metadata.lens &&
                decoded_gain_jpeg.metadata.iso == metadata.iso &&
                decoded_gain_jpeg.metadata.orientation == 1,
            "gain-map JPEG input did not preserve portable Exif");
    const float measured_gain_jpeg_peak = std::max(1.0F,
        *std::max_element(decoded_gain_jpeg.linear_p3.pixels.begin(),
                          decoded_gain_jpeg.linear_p3.pixels.end()));
    require(decoded_gain_jpeg.domain == hyperdr::InputDomain::kDualRendition &&
                decoded_gain_jpeg.authored_sdr.has_value() &&
                std::abs(decoded_gain_jpeg.hdr_headroom - measured_gain_jpeg_peak) < 1e-5F,
            "gain-map JPEG input did not preserve authored SDR and measured HDR range");
    require_linear_round_trip(decoded_gain_jpeg, expected_gain_jpeg,
                              "gain-map JPEG input did not reconstruct its Gain Map");
    // AVIF is the encoding this project could write but not read, so unlike the
    // other five it had no input round trip: `verify_avif_decodable` only ever
    // proved libavif would open the file, never that HyperDR would.
    const auto expected_avif = hyperdr::reconstruct_gain_map(
        small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
        small_gain.headroom_stops);
    for (const auto encoding :
         {hyperdr::HdrEncoding::AvifPq, hyperdr::HdrEncoding::AvifHlg}) {
      const bool pq = encoding == hyperdr::HdrEncoding::AvifPq;
      const auto avif = hyperdr::encode_avif(hyperdr::renditions_from_gain_map(small_gain), metadata, 80, encoding);
      require(avif.size() > 32, "AVIF encoder produced an implausibly small file");
      require(!contains_text(avif, "AdaptiveHDR") &&
                  !contains_text(avif, "ISO-21496-1"),
              "rendered AVIF incorrectly claims to carry a Gain Map");
      hyperdr::verify_avif_decodable(avif);
      require_avif_content_light(avif, expected_avif);
      const auto decoded =
          decode_encoded_input(avif, pq ? "avif-pq" : "avif-hlg", ".avif");
      const auto reduced_avif = decode_encoded_input(avif,
          pq ? "avif-pq-preview" : "avif-hlg-preview", ".avif", reduced_jpeg_options);
      require(reduced_avif.decode.sensor_width == decoded.decode.sensor_width &&
                  reduced_avif.decode.sensor_height == decoded.decode.sensor_height &&
                  reduced_avif.decode.target_width == decoded.decode.target_width &&
                  reduced_avif.decode.target_height == decoded.decode.target_height &&
                  reduced_avif.decode.decoded_width == 8 && reduced_avif.decode.decoded_height == 4 &&
                  reduced_avif.linear_p3.width == 8 && reduced_avif.linear_p3.height == 4 &&
                  !reduced_avif.decode.resolution_reduced,
              "AVIF preview lost full stored/target geometry");
      require_declared_headroom(
          decoded,
          pq ? 10000.0F / hyperdr::kReferenceWhiteNits
             : 1000.0F / hyperdr::kReferenceWhiteNits,
          pq ? "PQ AVIF did not preserve CICP headroom"
             : "HLG AVIF did not preserve CICP headroom");
      require_linear_round_trip(decoded, expected_avif,
                                pq ? "PQ AVIF input transfer round trip changed brightness"
                                   : "HLG AVIF input transfer round trip changed brightness");
      require_content_peak(decoded, expected_avif);
      require(reduced_avif.content_peak_nits == decoded.content_peak_nits,
              "AVIF preview changed declared content peak");
      require(decoded.metadata.model == metadata.model,
              "AVIF input did not carry its camera model back");
      require(decoded.capture.iso && *decoded.capture.iso == 100.0F,
              "AVIF input did not carry its ISO back");
    }
    std::cout << "PQ/HLG AVIF input round trips passed\n";
    check_png_cicp_headroom();
    auto no_headroom_options = options;
    no_headroom_options.headroom_stops = 0.0F;
    const auto no_headroom_gain = hyperdr::make_gain_map(small, no_headroom_options);
    hyperdr::verify_gain_map_jpeg(
        hyperdr::encode_gain_map_jpeg(no_headroom_gain, metadata, 20));
    auto gain_probe = small_gain;
    // This is the fixed-q95 code-preservation probe. P3a-2 gives ordinary
    // gain streams an independent lossy quality cap; framed streams retain
    // q95 for E5. Keep this path's original 0.5-mean / 3-max code limits.
    gain_probe.presentation_frame = true;
    for (std::size_t i = 0; i < gain_probe.gain_map.pixels.size(); ++i) {
      const auto code = i % 7 == 0 ? 0U : (i % 11 == 0 ? 255U : static_cast<unsigned>((i * 37U) % 255U));
      gain_probe.gain_map.pixels[i] = static_cast<float>(code) / 255.0F;
    }
    // The codes are synthetic, so the range they span is declared rather than
    // inherited from whatever the photographic renderer chose for `small`: the
    // headroom check below needs at least a stop for the preview divisor to use,
    // and the renderer's local weighting now gives this smooth gradient 0.6.
    gain_probe.metadata.gain_max = {2, 1};
    gain_probe.metadata.alternate_headroom = {2, 1};
    gain_probe.headroom_stops = 2.0F;
    const auto small8 = hyperdr::encode_adaptive_heic(gain_probe, metadata, 80, 8);
    check_structure(small8, "8-bit single");
    require_hevc_profiles(small8, false, true);
    decode_and_check(small8, 64, 32);
    check_gain_decode(small8, &gain_probe.gain_map);
    const auto expected_adaptive = hyperdr::reconstruct_gain_map(
        gain_probe.base_linear, gain_probe.gain_map,
        gain_probe.metadata, gain_probe.headroom_stops);
    require(contains_text(small8, "AdaptiveHDR") &&
                contains_text(small8, "ISO-21496-1:2025"),
            "Adaptive HEIC is missing its Gain Map XMP declaration");
    const auto decoded_adaptive = decode_encoded_input(small8, "adaptive");
    require(decoded_adaptive.metadata.model == metadata.model &&
                decoded_adaptive.metadata.lens == metadata.lens &&
                decoded_adaptive.metadata.iso == metadata.iso &&
                decoded_adaptive.metadata.orientation == 1,
            "Adaptive HEIC input did not preserve portable Exif");
    require_linear_round_trip(decoded_adaptive, expected_adaptive,
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
    auto perturbed_probe = gain_probe;
    for (auto& code : perturbed_probe.gain_map.pixels) {
      code = std::min(1.0F, code * 0.5F + 0.25F);
    }
    const auto perturbed8 = hyperdr::encode_adaptive_heic(perturbed_probe, metadata, 80, 8);
    display_curve_identity_check(small8, "8-bit single");
    display_curve_difference_check(small8, perturbed8, "8-bit single, perturbed Gain Map");

    // Single-image BT.2100 exports must be Main10, carry the requested transfer
    // function, remain distinct from gain-map topology, and decode end-to-end.
    for (const auto encoding : {hyperdr::HdrEncoding::Pq, hyperdr::HdrEncoding::Hlg}) {
        const auto hdr_bytes = hyperdr::encode_hdr_heic(hyperdr::renditions_from_gain_map(small_gain), metadata, 80, encoding);
        require_hevc_profiles(hdr_bytes, true, false);
        const auto inspection = hyperdr::inspect_heif(hdr_bytes);
        require(inspection.structurally_valid && inspection.has_heic_brand &&
                    !inspection.has_tmap_brand && !inspection.has_tmap_item &&
                    inspection.has_exif && inspection.has_xmp,
                "BT.2100 export has incorrect HEIF topology");
        require(!contains_text(hdr_bytes, "AdaptiveHDR") &&
                    !contains_text(hdr_bytes, "ISO-21496-1"),
                "rendered BT.2100 HEIC incorrectly claims to carry a Gain Map");
        hyperdr::verify_heic_decodable(hdr_bytes, encoding);
        const auto expected_hdr = hyperdr::reconstruct_gain_map(
            small_gain.base_linear, small_gain.gain_map, small_gain.metadata,
            small_gain.headroom_stops);
        const auto decoded = decode_encoded_input(
            hdr_bytes, encoding == hyperdr::HdrEncoding::Pq ? "pq" : "hlg");
        const auto reduced = decode_encoded_input(hdr_bytes,
            encoding == hyperdr::HdrEncoding::Pq ? "pq-preview" : "hlg-preview",
            ".heic", reduced_jpeg_options);
        // The stored ispe can include codec padding beyond the clean aperture.
        // Check it against the container, not the intended display dimensions.
        const auto geometry_file = hyperdr::read_heif(hdr_bytes);
        const auto geometry = geometry_file.resolve_image();
        require(geometry.color && geometry.color->matrix == 9,
                "BT.2100 HEIC must use the same Rec.2020 YCbCr matrix as AVIF");
        const auto expected_light = expected_content_light(expected_hdr);
        require(geometry.light && geometry.light->maximum == expected_light[0] &&
                    geometry.light->average == expected_light[1],
                "HEIC CLLI does not use maxRGB for MaxCLL and MaxPALL");
        require(reduced.decode.sensor_width == geometry.width &&
                    reduced.decode.sensor_height == geometry.height &&
                    reduced.decode.sensor_width == decoded.decode.sensor_width &&
                    reduced.decode.sensor_height == decoded.decode.sensor_height &&
                    reduced.decode.target_width == 64 && reduced.decode.target_height == 32 &&
                    reduced.decode.decoded_width == 8 && reduced.decode.decoded_height == 4 &&
                    reduced.linear_p3.width == 8 && reduced.linear_p3.height == 4 &&
                    !reduced.decode.resolution_reduced,
                "HEIC preview lost stored/target/delivered geometry");
        require_declared_headroom(
            decoded,
            encoding == hyperdr::HdrEncoding::Pq
                ? 10000.0F / hyperdr::kReferenceWhiteNits
                : 1000.0F / hyperdr::kReferenceWhiteNits,
            encoding == hyperdr::HdrEncoding::Pq
                ? "PQ HEIC did not preserve CICP headroom"
                : "HLG HEIC did not preserve CICP headroom");
        require_linear_round_trip(
            decoded, expected_hdr,
            encoding == hyperdr::HdrEncoding::Pq
                ? "PQ input transfer round trip changed brightness"
                : "HLG input transfer round trip changed brightness");
        require_content_peak(decoded, expected_hdr);
        require(reduced.content_peak_nits == decoded.content_peak_nits,
                "HEIC preview changed declared content peak");
        // The HEIF Exif item is prefixed with a four-byte TIFF offset, which is
        // exactly the kind of preamble the reader has to skip. Checking it here
        // keeps the container path honest as well as the AVIF one.
        require(decoded.metadata.model == metadata.model,
                "HEIC input did not carry its camera model back");
        require(decoded.capture.iso && *decoded.capture.iso == 100.0F,
                "HEIC input did not carry its ISO back");
    }
    std::cout << "PQ/HLG Main10 round trips passed\n";

    // Compare two decodes of the same compressed checkerboard, so codec loss
    // cancels out: reducing resolution must preserve the linear-light mean.
    auto checker_gain = small_gain;
    for (std::uint32_t y = 0; y < checker_gain.base_linear.height; ++y) {
      for (std::uint32_t x = 0; x < checker_gain.base_linear.width; ++x) {
        const float value = ((x / 2 + y / 2) % 2) ? 1.0F : 0.0F;
        const auto index = (static_cast<std::size_t>(y) * checker_gain.base_linear.width + x) * 3;
        for (int c = 0; c < 3; ++c) checker_gain.base_linear.pixels[index + c] = value;
      }
    }
    std::fill(checker_gain.gain_map.pixels.begin(), checker_gain.gain_map.pixels.end(), 0.0F);
    const auto linear_mean = [](const hyperdr::FloatImage& image) {
      double sum = 0.0;
      for (const float value : image.pixels) sum += value;
      return sum / static_cast<double>(image.pixels.size());
    };
    bool means_preserved = true;
    for (const auto encoding : {hyperdr::HdrEncoding::Pq, hyperdr::HdrEncoding::Hlg,
                               hyperdr::HdrEncoding::AvifPq, hyperdr::HdrEncoding::AvifHlg}) {
      const bool avif = encoding == hyperdr::HdrEncoding::AvifPq || encoding == hyperdr::HdrEncoding::AvifHlg;
      const bool pq = encoding == hyperdr::HdrEncoding::Pq || encoding == hyperdr::HdrEncoding::AvifPq;
      const auto bytes = avif ? hyperdr::encode_avif(hyperdr::renditions_from_gain_map(checker_gain), metadata, 90, encoding)
                              : hyperdr::encode_hdr_heic(hyperdr::renditions_from_gain_map(checker_gain), metadata, 90, encoding);
      const auto full = decode_encoded_input(bytes, "checker-full", avif ? ".avif" : ".heic");
      const auto reduced = decode_encoded_input(bytes, "checker-preview", avif ? ".avif" : ".heic",
                                                reduced_jpeg_options);
      const double full_mean = linear_mean(full.linear_p3);
      const double reduced_mean = linear_mean(reduced.linear_p3);
      std::cout << (avif ? "AVIF " : "HEIC ") << (pq ? "PQ" : "HLG")
                << " checker linear mean: full=" << full_mean << ", preview=" << reduced_mean << '\n';
      means_preserved = means_preserved && std::isfinite(full_mean) && std::isfinite(reduced_mean) &&
          std::abs(full_mean - reduced_mean) <= 1e-5 * std::max(1.0, std::abs(full_mean));
    }
    require(means_preserved, "HDR preview reduction did not preserve the decoded linear-light mean");

    // A camera-shaped HDR input: 10-bit BT.2100 HLG at 4:2:2. This is the only
    // chroma format no HyperDR output can stand in for, and the only one whose
    // decode depends on the HEVC range extensions.
    const auto hlg422 = encode_hlg_422(small);
    if (hlg422.empty()) {
      throw std::runtime_error("VideoToolbox cannot produce the required 4:2:2 Main10 fixture");
    }
    require_chroma_422(hlg422);
    const auto decoded_hlg422 = decode_encoded_input(hlg422, "hlg422");
    require_declared_headroom(
        decoded_hlg422, 1000.0F / hyperdr::kReferenceWhiteNits,
        "4:2:2 HLG input did not preserve CICP headroom");
    require_linear_round_trip(decoded_hlg422, small,
                              "4:2:2 HLG input did not decode to its linear values");
    std::cout << "4:2:2 HLG input round trip passed\n";
    check_hdr_source_gain_maps(metadata);
    std::cout << "HLG source to Adaptive HEIC and gain-map JPEG round trips passed\n";

    // 10-bit output is required: it is the only way to exercise the Main10
    // path used by the BT.2100 encodings.
    const auto bytes10 = hyperdr::encode_adaptive_heic(small_gain, metadata, 80, 10);
    check_structure(bytes10, "10-bit single");
    require_hevc_profiles(bytes10, true, true);
    decode_and_check(bytes10, 64, 32);
    reconstruct_and_check(bytes10, "10-bit single");
    display_curve_identity_check(bytes10, "10-bit single");
    std::cout << "10-bit Main10 round trip passed\n";

    std::cout << "codec/TMAP integration test passed (" << bytes8.size() << " bytes, grid)\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "codec test failure: " << e.what() << '\n';
    return 1;
  }
} catch (const std::exception& error) {
  std::cerr << "test failure: " << error.what() << '\n';
  return 1;
} catch (...) {
  std::cerr << "unknown test failure\n";
  return 1;
}
