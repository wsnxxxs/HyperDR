#include "hyperdr/app/settings.hpp"

#include "hyperdr/codec/availability.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace hyperdr {

void validate_encoding_headroom(HdrEncoding encoding, float headroom_stops) {
  if (is_hlg_encoding(encoding) &&
      (!(std::isfinite(headroom_stops)) ||
       headroom_stops > kHlgHeadroomStops + 1.0e-5F)) {
    throw std::invalid_argument(
        "HLG rendered headroom cannot exceed 2.3 stops at 203-nit diffuse white");
  }
}

void validate_convert_options(const ConvertOptions& options) {
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
  validate_raw_file(options.raw.bad_pixel_map, "RAW bad-pixel map");
  validate_raw_file(options.raw.dark_frame, "RAW dark frame");
  validate_raw_file(options.raw.linearization_lut, "RAW linearization LUT");
  validate_raw_file(options.raw.lens_shading_map, "RAW lens-shading map");
  // Ranges for the individual settings are enforced by the schema on the way in;
  // this catches the internal look parameters and the renderer's own invariants.
  validate_gain_map_options(options.gain);
}

}  // namespace hyperdr
