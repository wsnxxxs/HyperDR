#include "hyperdr/app/settings.hpp"

#include "hyperdr/codec/availability.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace hyperdr {

ColorGamut resolved_sdr_gamut(const ConvertOptions& options) {
  return options.output_gamut.value_or(options.encoding == OutputEncoding::SdrJpeg
      ? ColorGamut::kSrgb : ColorGamut::kDisplayP3);
}

void apply_output_color_options(ConvertOptions& options) {
  options.gain.hdr_gamut = is_bt2100_encoding(options.encoding)
      ? ColorGamut::kRec2020 : ColorGamut::kDisplayP3;
  // SDR output mapping happens after the creative grade. A retained HDR
  // chromaticity restriction must not silently change the TIFF/JPEG rendition.
  if (is_sdr_encoding(options.encoding)) options.clamp_srgb = false;
  options.gain.clamp_srgb = options.clamp_srgb;
}

bool uses_native_model(const ConvertOptions& options) {
  return !options.ai_model_path.empty();
}

std::string selected_native_model_id(const ConvertOptions& options) {
  if (options.ai_model_path.empty()) return {};
  return normalize_native_model_id(path_utf8(options.ai_model_path));
}

NativeModelRequest native_model_request(const ConvertOptions& options,
                                        const PhotoMetadata& metadata) {
  NativeModelRequest request;
  request.model_id = selected_native_model_id(options);
  request.capture = metadata.capture;
  return request;
}

void validate_encoding_headroom(HdrEncoding encoding, float headroom_stops) {
  if (is_hlg_encoding(encoding) &&
      (!(std::isfinite(headroom_stops)) ||
       headroom_stops > kHlgHeadroomStops + 1.0e-5F)) {
    throw std::invalid_argument(
        "HLG rendered headroom cannot exceed 2.3 stops at 203-nit diffuse white");
  }
}

void validate_convert_options(const ConvertOptions& options) {
  if (options.output_gamut && (!is_sdr_encoding(options.encoding) ||
      *options.output_gamut == ColorGamut::kRec2020))
    throw std::invalid_argument("--output-gamut selects sRGB or P3 for SDR JPEG/TIFF only");
  if (options.output_directory.empty()) {
    throw std::invalid_argument("--output is required");
  }
  if (options.decode_intent == DecodeIntent::Preview &&
      options.preview_max_edge == 0) {
    throw std::invalid_argument(
        "fast preview requires --preview-max-edge");
  }
  if ((options.decode_intent == DecodeIntent::Preview) !=
      options.raw.half_size) {
    throw std::invalid_argument(
        "RAW half-size decoding is permitted only for explicit previews");
  }
  if (options.encoding == HdrEncoding::UltraHdr && options.depth != 8) {
    throw std::invalid_argument(
        "Ultra HDR JPEG uses an 8-bit SDR base and requires --depth 8");
  }
  if (is_hlg_encoding(options.encoding) && !options.gain.auto_headroom &&
      options.gain.headroom_stops > kHlgHeadroomStops) {
    throw std::invalid_argument(
        "HLG headroom cannot exceed 2.3 stops at 203-nit diffuse white");
  }
  const bool has_external_gain = !options.external_gain_path.empty();
  const bool has_external_gain_report = !options.external_gain_report.empty();
  if (has_external_gain != has_external_gain_report) {
    throw std::invalid_argument(
        "external gain requires both --external-gain and --external-gain-report");
  }
  if (has_external_gain && options.recursive) {
    throw std::invalid_argument(
        "external gain is supported for one input at a time, not recursive batches");
  }
  if (!options.ai_model_path.empty() && has_external_gain) {
    throw std::invalid_argument(
        "--ai-model cannot be combined with an external gain grid");
  }
  // Resolve the model id once, here, so a run that names a model this build does
  // not have fails before any file is opened. The preview and batch paths both
  // reach the adapter through the same table, and neither can substitute the
  // incumbent for a misspelled id.
  (void)selected_native_model_id(options);
  validate_color_lut_options(options.color_lut);
  if (!options.color_lut.path.empty()) {
    (void)read_color_lut(options.color_lut.path);
    if ((!options.ai_model_path.empty() || has_external_gain) &&
        (options.color_lut.input == LutSpace::SLog3 || options.color_lut.input == LutSpace::Hlg || options.color_lut.input == LutSpace::Pq))
      throw std::invalid_argument("AI/external gain supports SDR creative LUTs; use manual rendering for Log/HLG/PQ LUTs");
  }
  if (options.encoding == HdrEncoding::SdrJpeg && options.depth != 8)
    throw std::invalid_argument("SDR JPEG requires --depth 8");
  validate_native_model_post_options(options.ai_post);
  if (has_external_gain) {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(options.external_gain_path, ec) || ec) {
      throw std::invalid_argument("external gain file does not exist");
    }
    ec.clear();
    if (!std::filesystem::is_regular_file(options.external_gain_report, ec) || ec) {
      throw std::invalid_argument("external gain report does not exist");
    }
  }
  if (!(std::isfinite(options.raw.digital_gain) &&
        options.raw.digital_gain > 0.0F && options.raw.digital_gain <= 64.0F)) {
    throw std::invalid_argument("RAW digital gain must be finite and in (0,64]");
  }
  const auto validate_raw_file = [](const std::filesystem::path& path,
                                    const char* label) {
    if (path.empty()) return;
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec) || ec) {
      throw std::invalid_argument(std::string(label) + " does not exist");
    }
  };
  validate_raw_file(options.raw.profile, "RAW DCP profile");
  validate_raw_file(options.raw.look_profile, "RAW XMP look");
  if (!options.raw.look_profile.empty() && options.raw.profile.empty())
    throw std::invalid_argument("--raw-look requires --raw-profile");
  validate_raw_file(options.raw.lens_profile, "RAW LCP profile");
  validate_raw_file(options.raw.bad_pixel_map, "RAW bad-pixel map");
  validate_raw_file(options.raw.dark_frame, "RAW dark frame");
  validate_raw_file(options.raw.linearization_lut, "RAW linearization LUT");
  validate_raw_file(options.raw.lens_shading_map, "RAW lens-shading map");
  // Ranges for the individual settings are enforced by the schema on the way in;
  // this catches the internal look parameters and the renderer's own invariants.
  validate_gain_map_options(options.gain);
}

}  // namespace hyperdr
