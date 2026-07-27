#pragma once

// One declarative table of every conversion setting, and everything derived
// from it.
//
// The same twenty-one settings used to be written out by hand five times: the
// usage text, the command-line parser, the settings-document loader, the resume
// fingerprint, and the report's settings block. Two of those five had already
// drifted -- the loader accepted keys the usage text did not mention, and
// the fingerprint covered fields the report omitted -- and a sixth copy lived in
// the panel's Python. Each setting is now described once, and parsing,
// validation, help, the fingerprint, the report and the schema the panel
// consumes are all generated from that description.
//
// `HyperDR schema --json` emits this table so the panel derives its own
// validation instead of mirroring it. schema/settings.json is that output,
// checked in, and CI fails if the two disagree.

#include "hyperdr/app/settings.hpp"
#include "hyperdr/foundation/json.hpp"

#include <span>
#include <string>
#include <string_view>

namespace hyperdr {

enum class SettingKind {
  // A name from a fixed set.
  kEnum,
  // A real number in [minimum, maximum].
  kNumber,
  // An integer in [minimum, maximum].
  kInteger,
  // True or false. On the command line it is a bare flag with no value.
  kBoolean,
  // The string "auto", or a number in [minimum, maximum]. Automatic selection
  // is a distinct state, not a sentinel value.
  kAutoOrNumber,
};

struct Setting {
  // Canonical name: the preset key, the report key, and the fingerprint field.
  std::string_view key;
  // Command-line flag including the dashes, or empty for a setting that is not
  // user-facing but still affects the encoded bytes and so must be fingerprinted.
  std::string_view flag;
  SettingKind kind{SettingKind::kNumber};
  double minimum{0.0};
  double maximum{0.0};
  std::span<const std::string_view> choices{};
  // Value placeholder for the usage text, e.g. "<0.80..1.35>".
  std::string_view value_label{};
  std::string_view help{};
  // A boolean flag whose presence sets the setting to false rather than true,
  // for `--no-verify`.
  bool flag_sets_false{false};
  // False for settings that cannot change the encoded bytes -- thread count,
  // verification, overwrite behaviour -- so toggling one does not invalidate a
  // resumable batch.
  bool affects_output_bytes{true};

  // Enum names this setting accepts beyond `choices`. `choices` is the
  // documented, canonical set; earlier releases accepted aliases for some of
  // them (`--encoding gain-map`, `jpegr`, `avif`), and silently rejecting those
  // would break stored presets and scripts. Null means "exactly `choices`".
  bool (*accepts_name)(std::string_view){nullptr};

  // The two halves of the reflection. `apply` is used by both the command-line
  // parser and the preset loader; `read` by the fingerprint, the report and the
  // schema's defaults.
  void (*apply)(ConvertOptions&, const json::Value&){nullptr};
  json::Value (*read)(const ConvertOptions&){nullptr};

  [[nodiscard]] bool presetable() const { return !flag.empty(); }
};

[[nodiscard]] std::span<const Setting> settings();
[[nodiscard]] const Setting* find_setting_by_key(std::string_view key);
[[nodiscard]] const Setting* find_setting_by_flag(std::string_view flag);

// Converts one command-line token into a canonical value, reporting the
// setting's own name and range on failure.
[[nodiscard]] json::Value parse_setting_text(const Setting& setting,
                                             std::string_view text);
// Rejects wrong types, unknown enum names, and out-of-range numbers.
void validate_setting_value(const Setting& setting, const json::Value& value);

// Applies a strict settings document: an object whose every member is a known,
// well-typed, in-range setting. An unknown key is an error, because silently
// ignoring one renders the image with settings the user did not ask for.
void apply_preset_document(const json::Value& document, ConvertOptions& options);

// The generated per-setting lines of the usage text.
[[nodiscard]] std::string settings_usage_text();
// The machine-readable description the panel consumes.
[[nodiscard]] std::string schema_json();

}  // namespace hyperdr
