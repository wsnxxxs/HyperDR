#include "hyperdr/app/fingerprint.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/version.hpp"

namespace hyperdr {

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
    else out += json::number_text(static_cast<float>(value.number()));
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
  const auto append_raw_file = [&](const char* key,
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
  append_raw_file("raw_bad_pixel_map", options.raw.bad_pixel_map);
  append_raw_file("raw_dark_frame", options.raw.dark_frame);
  append_raw_file("raw_linearization_lut", options.raw.linearization_lut);
  append_raw_file("raw_lens_shading_map", options.raw.lens_shading_map);
  return out;
}

std::string settings_fingerprint(const ConvertOptions& options) {
  return fnv1a_hex(settings_signature(options));
}

}  // namespace hyperdr
