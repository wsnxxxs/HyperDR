// The report and the curve export are what the browser panel reads back, so
// both have to be parseable and to carry the fields the panel looks for.
#include "hyperdr/app/report.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"

#include <cmath>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

const hyperdr::json::Value& resolve_schema(
    const hyperdr::json::Value& root, const hyperdr::json::Value& schema) {
  const auto* reference = schema.find("$ref");
  if (reference == nullptr) return schema;
  constexpr std::string_view prefix = "#/$defs/";
  const auto& text = reference->string();
  require(text.starts_with(prefix), "unsupported report-schema reference: " + text);
  const auto* definitions = root.find("$defs");
  const auto* resolved = definitions == nullptr
                             ? nullptr
                             : definitions->find(text.substr(prefix.size()));
  require(resolved != nullptr, "unresolved report-schema reference: " + text);
  return *resolved;
}

bool scalar_equal(const hyperdr::json::Value& left,
                  const hyperdr::json::Value& right) {
  if (left.type() != right.type()) return false;
  if (left.is_null()) return true;
  if (left.is_bool()) return left.boolean() == right.boolean();
  if (left.is_number()) return left.number() == right.number();
  if (left.is_string()) return left.string() == right.string();
  return false;
}

bool type_matches(const hyperdr::json::Value& value, std::string_view type) {
  if (type == "null") return value.is_null();
  if (type == "boolean") return value.is_bool();
  if (type == "number") return value.is_number();
  if (type == "integer") {
    return value.is_number() && value.number() == std::floor(value.number());
  }
  if (type == "string") return value.is_string();
  if (type == "array") return value.is_array();
  if (type == "object") return value.is_object();
  return false;
}

bool validates(const hyperdr::json::Value& root,
               const hyperdr::json::Value& candidate,
               const hyperdr::json::Value& unresolved_schema,
               const std::string& path, std::string& error) {
  const auto& schema = resolve_schema(root, unresolved_schema);

  if (const auto* alternatives = schema.find("oneOf")) {
    int matches = 0;
    for (const auto& alternative : alternatives->array()) {
      std::string ignored;
      if (validates(root, candidate, alternative, path, ignored)) ++matches;
    }
    if (matches != 1) {
      error = path + " does not match exactly one report-schema alternative";
      return false;
    }
  }
  if (const auto* constant = schema.find("const");
      constant != nullptr && !scalar_equal(candidate, *constant)) {
    error = path + " does not match its report-schema constant";
    return false;
  }
  if (const auto* choices = schema.find("enum")) {
    bool found = false;
    for (const auto& choice : choices->array()) found |= scalar_equal(candidate, choice);
    if (!found) {
      error = path + " is not in its report-schema enum";
      return false;
    }
  }
  if (const auto* type = schema.find("type")) {
    bool matches = false;
    if (type->is_string()) {
      matches = type_matches(candidate, type->string());
    } else {
      for (const auto& name : type->array()) {
        matches |= type_matches(candidate, name.string());
      }
    }
    if (!matches) {
      error = path + " has the wrong report-schema type";
      return false;
    }
  }

  if (candidate.is_object()) {
    if (const auto* required = schema.find("required")) {
      for (const auto& name : required->array()) {
        if (candidate.find(name.string()) == nullptr) {
          error = path + " is missing required member " + name.string();
          return false;
        }
      }
    }
    const auto* properties = schema.find("properties");
    for (const auto& [name, value] : candidate.members()) {
      const auto* property = properties == nullptr ? nullptr : properties->find(name);
      if (property == nullptr) {
        if (const auto* additional = schema.find("additionalProperties");
            additional != nullptr && additional->is_bool() &&
            !additional->boolean()) {
          error = path + " contains undocumented member " + name;
          return false;
        }
        continue;
      }
      if (!validates(root, value, *property, path + "." + name, error)) return false;
    }
  }
  if (candidate.is_array()) {
    if (const auto* items = schema.find("items")) {
      for (std::size_t i = 0; i < candidate.array().size(); ++i) {
        if (!validates(root, candidate.array()[i], *items,
                       path + "[" + std::to_string(i) + "]", error)) {
          return false;
        }
      }
    }
  }
  return true;
}

void test_run_report_is_parseable_and_complete() {
  hyperdr::ConvertOptions options;
  options.encoding = hyperdr::HdrEncoding::Pq;
  options.depth = 8;

  hyperdr::FileResult ok;
  ok.input = "in/photo.ARW";
  ok.output = "out/photo-hyperdr.heic";
  ok.success = true;
  ok.self_verified = true;
  ok.message = "ok";
  ok.sensor_width = 9600;
  ok.sensor_height = 6400;
  ok.target_width = 9504;
  ok.target_height = 6336;
  ok.decoded_width = 4752;
  ok.decoded_height = 3168;
  ok.target_dimensions_applied = true;
  ok.default_crop_present = true;
  ok.decode_degraded = true;
  ok.decode_degradation_reasons = {"default_crop_rejected"};
  ok.width = 8192;
  ok.height = 5464;
  ok.stats.rendered_peak = 3.5F;
  hyperdr::FileResult failed;
  failed.input = "in/broken.ARW";
  failed.message = R"(cannot read "broken": unexpected end)";

  const auto document = hyperdr::json::parse(
      hyperdr::run_report_json({ok, failed}, options));
  require(document.find("schema")->number() == 6, "report schema version missing");
  const auto* settings = document.find("settings");
  require(settings != nullptr, "report has no settings block");
  // Generated from the table, so every setting is present without anyone
  // maintaining a second list.
  for (const auto& setting : hyperdr::settings()) {
    require(settings->find(setting.key) != nullptr,
            std::string(setting.key) + " is missing from the report");
  }
  // BT.2100 is always 10-bit regardless of the requested base depth.
  require(settings->find("output_depth")->number() == 10, "output depth was not corrected");

  const auto& files = document.find("files")->array();
  require(files.size() == 2, "report file count wrong");
  require(files[0].find("success")->boolean(), "successful file not recorded");
  require(files[0].find("sensor_width")->number() == 9600,
          "RAW sensor dimensions missing");
  require(files[0].find("target_width")->number() == 9504,
          "DefaultCrop target dimensions missing");
  require(files[0].find("decoded_width")->number() == 4752,
          "actual decode dimensions missing");
  require(files[0].find("decode_degraded")->boolean(),
          "decode degradation was not reported");
  // Types are pinned, not just values: the panel branches on
  // target_dimensions_applied and joins the reasons, so a reason emitted as a
  // bare string again -- or the predicate emitted as a number -- would break it
  // in the browser rather than here.
  require(files[0].find("target_dimensions_applied")->is_bool() &&
              files[0].find("target_dimensions_applied")->boolean(),
          "target_dimensions_applied must be a boolean predicate");
  require(files[0].find("default_crop_present")->is_bool(),
          "default_crop_present must be a boolean");
  const auto* reasons = files[0].find("decode_degradation_reasons");
  require(reasons != nullptr && reasons->is_array(),
          "decode degradation reasons must be a JSON array");
  require(reasons->array().size() == 1 && reasons->array().front().is_string() &&
              reasons->array().front().string() == "default_crop_rejected",
          "decode degradation reason missing");
  // The failed entry never decoded, so it must still emit the array rather than
  // omitting the key and forcing every consumer to handle undefined.
  const auto* empty_reasons = files[1].find("decode_degradation_reasons");
  require(empty_reasons != nullptr && empty_reasons->is_array() &&
              empty_reasons->array().empty(),
          "an absent degradation list must be an empty array, not missing");
  require(files[0].find("render")->find("rendered_peak")->number() == 3.5,
          "render stats missing");
  require(files[0].find("gain_map")->find("percentiles_stops") != nullptr,
          "gain distribution missing");
  require(files[1].find("message")->string() == R"(cannot read "broken": unexpected end)",
          "a quoted failure message was not escaped correctly");
  require(files[1].find("look")->find("ev100")->is_null(),
          "an absent EV100 was not null");

  const auto schema_bytes = hyperdr::read_binary_file(
      std::filesystem::path(HYPERDR_SOURCE_DIR) / "schema" / "report.json");
  const auto schema = hyperdr::json::parse(std::string(
      reinterpret_cast<const char*>(schema_bytes.data()), schema_bytes.size()));
  std::string schema_error;
  require(validates(schema, document, schema, "$", schema_error), schema_error);
}

void test_curve_export_matches_the_requested_settings() {
  hyperdr::GainMapOptions gain;
  gain.auto_headroom = false;
  gain.headroom_stops = 2.5F;
  gain.look.contrast = 1.2F;
  const auto document = hyperdr::json::parse(hyperdr::look_curve_json(gain, 33));
  require(document.find("samples")->number() == 33, "sample count wrong");
  require(document.find("headroom_stops")->number() == 2.5, "headroom not reported");
  require(document.find("contrast")->number() == 1.2, "contrast not reported");
  const auto& sdr = document.find("sdr")->array();
  const auto& gain_stops = document.find("gain_stops")->array();
  require(sdr.size() == 33 && gain_stops.size() == 33, "curve array length wrong");
  require(sdr.front().number() == 0.0 && sdr.back().number() == 1.0,
          "the SDR grid is not the unit interval");
  // Below the shoulder the two renditions are identical by construction.
  require(gain_stops.front().number() == 0.0, "black gained brightness");
  require(gain_stops.back().number() > 0.0, "white did not expand");

  // Automatic headroom is content dependent, so the exported curve uses the
  // configured ceiling instead of inventing a number.
  hyperdr::GainMapOptions automatic;
  automatic.look.headroom_max_stops = 3.0F;
  require(hyperdr::json::parse(hyperdr::look_curve_json(automatic, 5))
                  .find("headroom_stops")
                  ->number() == 3.0,
          "an automatic curve did not fall back to the ceiling");
}

}  // namespace

int main() {
  try {
    test_run_report_is_parseable_and_complete();
    test_curve_export_matches_the_requested_settings();
    std::cout << "report tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
