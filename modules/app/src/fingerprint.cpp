#include "hyperdr/app/fingerprint.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/version.hpp"

#include <array>
#include <cstdio>
#include <stdexcept>

namespace hyperdr {
namespace {

std::string exact_number_text(double value) {
  std::array<char, 32> buffer{};
  const int written =
      std::snprintf(buffer.data(), buffer.size(), "%.17g", value);
  if (written <= 0 || static_cast<std::size_t>(written) >= buffer.size()) {
    throw std::invalid_argument("setting number does not fit its text form");
  }
  return std::string(buffer.data(), static_cast<std::size_t>(written));
}

}  // namespace

std::array<RawDecodeResource, 4> raw_decode_resources(
    const RawDecodeOptions& options) {
  return {{{"raw_bad_pixel_map", options.bad_pixel_map},
           {"raw_dark_frame", options.dark_frame},
           {"raw_linearization_lut", options.linearization_lut},
           {"raw_lens_shading_map", options.lens_shading_map}}};
}

std::string settings_signature(const ConvertOptions& options) {
  // The version is part of the signature: a renderer change with identical
  // settings still produces different bytes, and a resumed batch must notice.
  std::string out = std::string("hyperdr:") + kVersion;
  for (const auto& setting : settings()) {
    if (!setting.affects_output_bytes) continue;
    const json::Value value = setting.read(options);
    out += '|';
    out += setting.key;
    out += '=';
    if (value.is_string()) out += value.string();
    else if (value.is_bool()) out += value.boolean() ? "1" : "0";
    else out += exact_number_text(value.number());
  }
  // External model output is part of the encoded bytes even though it is not
  // a renderer setting. Hash both files so --skip-existing cannot reuse a
  // result after a model output or inference sidecar changes in place.
  if (!options.external_gain_path.empty()) {
    out += "|external_gain=";
    out += path_utf8(options.external_gain_path);
    out += '=';
    out += sha256_file_hex(options.external_gain_path);
    out += "|external_gain_report=";
    out += path_utf8(options.external_gain_report);
    out += '=';
    out += sha256_file_hex(options.external_gain_report);
    out += "|allow_legacy_external_gain=";
    out += options.allow_legacy_external_gain ? "1" : "0";
  }
  const auto append_raw_file = [&](std::string_view key,
                                   const std::filesystem::path& path) {
    if (path.empty()) return;
    out += '|';
    out += key;
    out += '=';
    out += path_utf8(path);
    out += ':';
    out += sha256_file_hex(path);
  };
  // Calibration files are external inputs, not schema scalar settings. Their
  // paths and contents still belong in the resume fingerprint: changing a
  // dark frame or lens grid must never be hidden by --skip-existing.
  for (const auto& resource : raw_decode_resources(options.raw)) {
    append_raw_file(resource.key, resource.path);
  }
  return out;
}

std::string settings_fingerprint(const ConvertOptions& options) {
  return fnv1a_hex(settings_signature(options));
}

}  // namespace hyperdr
