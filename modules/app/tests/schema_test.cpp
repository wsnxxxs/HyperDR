// The settings table is now the single source of truth for parsing, presets,
// help, the fingerprint and the report. These are the properties the five
// hand-written copies it replaced could not guarantee between them.
#include "hyperdr/app/schema.hpp"

#include "hyperdr/app/fingerprint.hpp"

#include <functional>
#include <iostream>
#include <set>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

bool throws(const std::function<void()>& fn) {
  try {
    fn();
  } catch (const std::exception&) {
    return true;
  }
  return false;
}

void test_table_is_well_formed() {
  std::set<std::string> keys;
  std::set<std::string> flags;
  for (const auto& setting : hyperdr::settings()) {
    require(!setting.key.empty(), "a setting has no key");
    require(keys.insert(std::string(setting.key)).second,
            "duplicate setting key: " + std::string(setting.key));
    require(setting.read != nullptr, std::string(setting.key) + " has no reader");
    if (setting.presetable()) {
      require(setting.flag.starts_with("--"),
              std::string(setting.key) + " has a malformed flag");
      require(flags.insert(std::string(setting.flag)).second,
              "duplicate flag: " + std::string(setting.flag));
      require(setting.apply != nullptr,
              std::string(setting.key) + " is settable but has no writer");
      require(!setting.help.empty(), std::string(setting.key) + " has no help text");
    }
    if (setting.kind == hyperdr::SettingKind::kEnum) {
      require(!setting.choices.empty(), std::string(setting.key) + " has no choices");
    } else if (setting.kind != hyperdr::SettingKind::kBoolean) {
      require(setting.maximum >= setting.minimum,
              std::string(setting.key) + " has an inverted range");
    }
  }
}

void test_every_setting_round_trips_through_its_accessors() {
  hyperdr::ConvertOptions options;
  for (const auto& setting : hyperdr::settings()) {
    if (setting.apply == nullptr) continue;
    const auto original = setting.read(options);
    setting.apply(options, original);
    const auto restored = setting.read(options);
    require(original.type() == restored.type(),
            std::string(setting.key) + " changed type through its accessors");
    if (original.is_number()) {
      require(original.number() == restored.number(),
              std::string(setting.key) + " did not round trip");
    } else if (original.is_string()) {
      require(original.string() == restored.string(),
              std::string(setting.key) + " did not round trip");
    } else {
      require(original.boolean() == restored.boolean(),
              std::string(setting.key) + " did not round trip");
    }
  }
}

void test_parsing_enforces_ranges_and_types() {
  const auto* contrast = hyperdr::find_setting_by_key("contrast");
  require(contrast != nullptr, "contrast is missing from the table");
  require(hyperdr::parse_setting_text(*contrast, "1.20").number() == 1.20,
          "a valid number was not parsed");
  require(throws([&] { hyperdr::parse_setting_text(*contrast, "5"); }),
          "an out-of-range number was accepted");
  require(throws([&] { hyperdr::parse_setting_text(*contrast, "abc"); }),
          "non-numeric text was accepted");

  // Aliases earlier releases accepted stay valid without being advertised as
  // canonical choices, so stored presets and scripts keep working.
  const auto* encoding = hyperdr::find_setting_by_key("encoding");
  for (const char* alias : {"gain-map", "ultra-hdr", "jpegr", "avif"}) {
    require(hyperdr::parse_setting_text(*encoding, alias).string() == alias,
            std::string("the legacy encoding alias ") + alias + " was rejected");
  }
  require(throws([&] { hyperdr::parse_setting_text(*encoding, "webp"); }),
          "an unknown encoding was accepted");

  const auto* look = hyperdr::find_setting_by_key("look");
  require(hyperdr::parse_setting_text(*look, "neutral").string() == "neutral",
          "a valid enum name was not parsed");
  require(throws([&] { hyperdr::parse_setting_text(*look, "cinematic"); }),
          "an unknown enum name was accepted");

  // "auto" is a distinct state, not a sentinel number.
  const auto* headroom = hyperdr::find_setting_by_key("headroom");
  require(hyperdr::parse_setting_text(*headroom, "auto").is_string(),
          "auto was not preserved as a name");
  require(hyperdr::parse_setting_text(*headroom, "2.5").number() == 2.5,
          "an explicit headroom was not parsed");
  require(throws([&] { hyperdr::parse_setting_text(*headroom, "maximum"); }),
          "an arbitrary name was accepted for an auto-or-number setting");

  // A boolean flag carries no value; --no-verify inverts.
  const auto* verify = hyperdr::find_setting_by_key("verify_output");
  require(verify->flag == "--no-verify", "verify_output lost its inverted flag");
  require(hyperdr::parse_setting_text(*verify, "").boolean() == false,
          "--no-verify did not clear verification");
  const auto* recursive = hyperdr::find_setting_by_key("recursive");
  require(hyperdr::parse_setting_text(*recursive, "").boolean(),
          "a plain boolean flag did not set its setting");

  const auto* preview = hyperdr::find_setting_by_key("preview_max_edge");
  hyperdr::ConvertOptions preview_options;
  preview->apply(preview_options, hyperdr::json::Value::from_number(2048));
  require(preview_options.decode_intent == hyperdr::DecodeIntent::Export &&
              !preview_options.raw.half_size,
          "a pure size bound changed decode intent");
  preview_options.output_directory = "output";
  hyperdr::validate_convert_options(preview_options);

  preview_options.decode_intent = hyperdr::DecodeIntent::Preview;
  preview_options.raw.half_size = true;
  hyperdr::validate_convert_options(preview_options);
}

void test_presets_reject_anything_unexpected() {
  hyperdr::ConvertOptions options;
  const auto apply = [&](const std::string& text) {
    hyperdr::apply_preset_document(hyperdr::json::parse(text), options);
  };
  apply(R"({"contrast":1.2,"look":"neutral","headroom":"auto","recursive":true})");
  require(options.gain.look.contrast == 1.2F, "a preset value was not applied");
  require(options.gain.look.mode == hyperdr::LookMode::kNeutral, "look was not applied");
  require(options.gain.auto_headroom, "auto headroom was not applied");
  require(options.recursive, "a boolean preset value was not applied");

  require(throws([&] { apply(R"({"contrst":1.1})"); }), "a misspelled key was accepted");
  require(throws([&] { apply(R"({"contrast":5.0})"); }), "an out-of-range value was accepted");
  require(throws([&] { apply(R"({"contrast":"1.1"})"); }), "a string number was accepted");
  require(throws([&] { apply(R"({"verify_output":"yes"})"); }), "a string bool was accepted");
  require(throws([&] { apply(R"([1,2])"); }), "a non-object preset was accepted");
  // Internal settings are fingerprinted but must not be settable from a preset.
  require(throws([&] { apply(R"({"toe_end":0.1})"); }), "an internal setting was settable");
  // A report file is not a preset, but its "schema" member should not be the
  // error the user hears about first.
  apply(R"({"schema":5})");
}

void test_fingerprint_covers_exactly_the_byte_affecting_settings() {
  const hyperdr::ConvertOptions base;
  const auto baseline = hyperdr::settings_fingerprint(base);
  for (const auto& setting : hyperdr::settings()) {
    if (setting.affects_output_bytes) {
      require(hyperdr::settings_signature(base).find(std::string(setting.key) + "=") !=
                  std::string::npos,
              std::string(setting.key) + " affects the bytes but is not fingerprinted");
    } else {
      require(hyperdr::settings_signature(base).find(std::string(setting.key) + "=") ==
                  std::string::npos,
              std::string(setting.key) + " cannot change the bytes but is fingerprinted");
    }
  }
  auto looser = base;
  looser.gain.look.contrast += 0.05F;
  require(hyperdr::settings_fingerprint(looser) != baseline,
          "a look change did not change the fingerprint");
  auto plumbing = base;
  plumbing.verify_output = false;
  plumbing.overwrite = true;
  require(hyperdr::settings_fingerprint(plumbing) == baseline,
          "a setting that cannot change the bytes invalidated the fingerprint");
}

void test_schema_document_describes_every_settable_option() {
  const auto document = hyperdr::json::parse(hyperdr::schema_json());
  const auto& entries = document.find("settings")->array();
  std::size_t settable = 0;
  for (const auto& setting : hyperdr::settings()) {
    if (setting.presetable()) ++settable;
  }
  require(entries.size() == settable, "the schema and the table disagree on size");
  for (const auto& entry : entries) {
    const auto& key = entry.find("key")->string();
    const auto* setting = hyperdr::find_setting_by_key(key);
    require(setting != nullptr, "the schema described an unknown setting: " + key);
    require(entry.find("flag")->string() == setting->flag, key + " flag mismatch");
    require(entry.find("default") != nullptr, key + " has no default");
    require(entry.find("help") != nullptr, key + " has no help");
  }
}

void test_usage_text_lists_every_flag() {
  const auto usage = hyperdr::settings_usage_text();
  for (const auto& setting : hyperdr::settings()) {
    if (!setting.presetable()) continue;
    require(usage.find(std::string(setting.flag)) != std::string::npos,
            std::string(setting.flag) + " is missing from the usage text");
  }
}

}  // namespace

int main() {
  try {
    test_table_is_well_formed();
    test_every_setting_round_trips_through_its_accessors();
    test_parsing_enforces_ranges_and_types();
    test_presets_reject_anything_unexpected();
    test_fingerprint_covers_exactly_the_byte_affecting_settings();
    test_schema_document_describes_every_settable_option();
    test_usage_text_lists_every_flag();
    std::cout << "settings schema tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
