#include "hyperdr/app/engine.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <array>
#include <cmath>
#include <cstdio>

namespace hyperdr {
namespace {
using Object = std::map<std::string, json::Value>;
using Value = json::Value;
constexpr std::pair<const char*, const char*> kCreativeFlags[] = {
    {"--contrast", "contrast"}, {"--vibrance", "vibrance"},
    {"--gain-strength", "gain_strength"}, {"--headroom-max", "headroom_max"},
    {"--pop", "pop"}, {"--exposure-bias", "exposure_bias"},
    {"--expansion-start", "expansion_start"}, {"--area-coverage", "area_coverage"}};
Value text(std::string value) { return Value::from_string(std::move(value)); }
Value number(double value) { return Value::from_number(value); }
Value boolean(bool value) { return Value::from_bool(value); }
std::string serialize(const Value& value) {
  switch (value.type()) {
    case json::Type::kNull: return "null";
    case json::Type::kBool: return value.boolean() ? "true" : "false";
    case json::Type::kNumber: return json::number_text(value.number());
    case json::Type::kString: return '"' + json::escape(value.string()) + '"';
    case json::Type::kObject: {
      std::string out = "{";
      for (const auto& [key, member] : value.members()) {
        if (out.size() > 1) out += ',';
        out += '"' + json::escape(key) + "\":" + serialize(member);
      }
      return out + '}';
    }
    case json::Type::kArray: {
      std::string out = "[";
      for (const auto& member : value.array()) {
        if (out.size() > 1) out += ',';
        out += serialize(member);
      }
      return out + ']';
    }
  }
  throw std::invalid_argument("invalid JSON type");
}
// The engine schema is the only place a default is written down.
Value schema_default(std::string_view key) { return setting_default(*find_setting_by_key(key)); }
Value get(const Value& object, std::string_view key, Value fallback) {
  const auto* value = object.find(key);
  return value ? *value : std::move(fallback);
}
bool truthy(const Value& value) {
  if (value.is_null()) return false;
  if (value.is_bool()) return value.boolean();
  if (value.is_number()) return value.number() != 0;
  if (value.is_string()) return !value.string().empty();
  return value.is_array() ? !value.array().empty() : !value.members().empty();
}
std::string fmt(const Value& value) {
  std::array<char, 64> buffer{};
  std::snprintf(buffer.data(), buffer.size(), "%.3f", value.number());
  std::string result(buffer.data());
  while (result.ends_with('0')) result.pop_back();
  if (result.ends_with('.')) result.pop_back();
  return result;
}
const Value& required(const Value& object, std::string_view key) {
  const auto* value = object.find(key);
  if (!value) throw std::invalid_argument(std::string(key) + " is required");
  return *value;
}
Value canonical_settings(const Value& request) {
  if (!request.is_object()) throw std::invalid_argument("request must be a JSON object");
  if (const auto* settings = request.find("settings")) return *settings;
  auto settings = request.members();
  settings.erase("command");
  return Value::from_object(std::move(settings));
}
}  // namespace

std::string normalize_options(const Value& edit) {
  if (!edit.is_object()) throw std::invalid_argument("edit options must be a JSON object");
  const bool model = truthy(get(edit, "_model_mode", Value{}));
  // The canonical name goes into the document, so `ultrahdr` from the Web
  // reference panel normalizes to the same bytes as `iso-gainmap-jpeg`.
  const auto requested = get(edit, "encoding", text("adaptive"));
  validate_setting_value(*find_setting_by_key("encoding"), requested);
  const auto parsed = hdr_encoding_from_name(requested.string());
  if (!parsed) throw std::invalid_argument("unknown encoding: " + requested.string());
  const auto encoding = text(hdr_encoding_name(*parsed));
  const bool sdr = is_sdr_encoding(*parsed);
  const bool hlg = is_hlg_encoding(*parsed);
  const auto output = get(edit, "outputGamut", schema_default("output_gamut"));
  if (output.string() != "auto" && output.string() != "srgb" && output.string() != "p3") {
    throw std::invalid_argument("outputGamut must be auto, srgb or p3");
  }
  // `hdrRange` absent or negative means automatic headroom (the schema's default),
  // as for aiHdrRange. A number fixes it. The model path has its own fixed recipe.
  const auto* range = model ? nullptr : edit.find("hdrRange");
  const bool automatic_headroom = !model && (!range || (range->is_number() && range->number() < 0));
  const auto kHlgCeiling = number(shortest_float_value(kHlgHeadroomStops));
  Value headroom, headroom_max;
  if (model) headroom = headroom_max = hlg ? kHlgCeiling : number(2.5);
  else if (automatic_headroom) {
    headroom = schema_default("headroom");
    headroom_max = schema_default("headroom_max");
  } else headroom = headroom_max = *range;
  if (hlg && headroom.is_number() && headroom.number() > kHlgCeiling.number()) {
    throw std::invalid_argument("HLG dynamic range cannot exceed 2.3 stops");
  }
  // Recipe values the model path forces are not defaults; everything else comes from the schema.
  const auto adjustable = [&](const char* edit_key, const char* setting_key, Value forced) {
    return model ? std::move(forced) : get(edit, edit_key, schema_default(setting_key));
  };
  Object settings{
      {"encoding", encoding}, {"look", schema_default("look")},
      {"color_gamut", get(edit, "colorGamut", schema_default("color_gamut"))},
      {"clamp_srgb", sdr ? boolean(false) : get(edit, "clampSrgb", schema_default("clamp_srgb"))},
      {"raw_lens_correction", get(edit, "lensCorrection", schema_default("raw_lens_correction"))},
      {"lut_input", get(edit, "lutInput", schema_default("lut_input"))},
      {"lut_output", get(edit, "lutOutput", schema_default("lut_output"))},
      {"lut_strength", get(edit, "lutStrength", schema_default("lut_strength"))},
      {"contrast", adjustable("contrast", "contrast", number(1))},
      {"vibrance", adjustable("vibrance", "vibrance", number(0))},
      {"gain_strength", get(edit, "hdrStrength", schema_default("gain_strength"))},
      {"pop", schema_default("pop")}, {"headroom_max", headroom_max}, {"headroom", headroom},
      {"exposure", schema_default("exposure")},
      {"exposure_bias", adjustable("brightness", "exposure_bias", number(0))},
      {"expansion_start", adjustable("expansionStart", "expansion_start", number(.25))},
      {"area_coverage", adjustable("areaCoverage", "area_coverage", number(1))},
      {"quality", get(edit, "quality", schema_default("quality"))},
      {"hevc_preset", get(edit, "hevcPreset", schema_default("hevc_preset"))}};
  if (sdr) settings.emplace("output_gamut", output);
  // Validate without converting doubles to the renderer's floats: the canonical
  // document must preserve the Python adapter's numbers exactly.
  for (const auto& [key, value] : settings) validate_setting_value(*find_setting_by_key(key), value);

  // Command metadata identifies adapter output without changing the canonical
  // renderer settings or the Python settings/argv golden documents.
  Object command{{"adapter", text("panel-v1")}};
  for (auto key : {"input", "output", "report", "external_gain", "external_gain_report",
      "_lut_path"}) {
    if (const auto* value = edit.find(key)) {
      value->string();
      command.emplace(key, *value);
    }
  }
  const bool external = truthy(get(edit, "external_gain", Value{}));
  const bool external_report = truthy(get(edit, "external_gain_report", Value{}));
  if (external != external_report) throw std::invalid_argument("external gain requires both raw grid and JSON report");
  if (model && external) throw std::invalid_argument("native AI model cannot be combined with external gain");
  command["model_mode"] = boolean(model);
  const auto domain = get(edit, "sourceDomain", text("")).string();
  const bool adaptive = *parsed == OutputEncoding::Adaptive;
  command["depth"] = number(adaptive && (domain == "display-referred-hdr" || domain == "dual-rendition")
      ? 10 : is_gain_map_encoding(*parsed) || sdr ? 8 : 10);
  if (model) {
    auto id = get(edit, "_model_id", text("embedded"));
    if (!id.is_string() || id.string().empty()) id = text("embedded");
    command["model_id"] = id;
    struct Post { const char* key; const char* flag; double initial, low, high; };
    constexpr Post posts[] = {{"aiBrightness", "--ai-brightness", 0,-1,1},
      {"aiContrast", "--ai-contrast", 1,.8,1.35}, {"aiShadows", "--ai-shadows", 0,-1,1},
      {"aiHighlights", "--ai-highlights", 0,-1,1}, {"aiHdrRange", "--ai-hdr-range", -1,-1,4},
      {"aiExpansionStart", "--ai-expansion-start", -1,-1,.75}};
    for (const auto& post : posts) {
      auto value = get(edit, post.key, number(post.initial));
      if (!value.is_number() || !std::isfinite(value.number()) || value.number() < post.low || value.number() > post.high ||
          (hlg && std::string_view(post.key) == "aiHdrRange" && value.number() > kHlgCeiling.number())) {
        throw std::invalid_argument(std::string(post.key) + " is out of range");
      }
      command[post.flag] = value;
    }
  }
  settings.emplace("command", Value::from_object(std::move(command)));
  return serialize(Value::from_object(std::move(settings))) + '\n';
}

std::vector<std::string> command_line(const Value& normalized) {
  const auto settings = canonical_settings(normalized);
  ConvertOptions validated;
  apply_preset_document(settings, validated);
  const auto& command = required(normalized, "command");
  const auto value = [&](std::string_view key) -> const Value& { return required(settings, key); };
  const auto cmd = [&](std::string_view key) -> const Value& { return required(command, key); };
  const bool model = cmd("model_mode").boolean();
  const bool external = truthy(get(command, "external_gain", Value{}));
  const auto* frame = command.find("frame");
  if (frame && !frame->is_null() && (!frame->is_string() || frame->string().empty()))
    throw std::invalid_argument("a framed request has no command-line form; write the frame to a file for --frame");
  std::vector<std::string> args{"HyperDR", "convert", cmd("input").string(), "--output", cmd("output").string(),
      "--encoding", hdr_encoding_name(validated.encoding)};
  const auto flag = [&](const char* name, std::string val) { args.emplace_back(name); args.push_back(std::move(val)); };
  if (frame && frame->is_string()) flag("--frame", frame->string());
  if (!model && !external) {
    flag("--look", value("look").string());
    for (const auto& [name, key] : kCreativeFlags) flag(name, fmt(value(key)));
    flag("--exposure", "auto");
    flag("--headroom", value("headroom").is_string() ? value("headroom").string() : fmt(value("headroom")));
  } else flag("--gain-strength", fmt(value("gain_strength")));
  if (!value("raw_lens_correction").boolean()) args.emplace_back("--no-raw-lens-correction");
  flag("--quality", fmt(value("quality")));
  flag("--depth", fmt(cmd("depth")));
  flag("--report", cmd("report").string());
  if (model) flag("--ai-model", cmd("model_id").string());
  if (external) {
    flag("--external-gain", cmd("external_gain").string());
    flag("--external-gain-report", cmd("external_gain_report").string());
  }
  // The command line carries every value, so it does not depend on the CLI's own defaults.
  flag("--color-gamut", value("color_gamut").string());
  if (is_sdr_encoding(validated.encoding)) flag("--output-gamut", value("output_gamut").string());
  if (value("clamp_srgb").boolean()) args.emplace_back("--clamp-srgb");
  for (const auto& [key, name] : {std::pair{"_lut_path","--lut"}}) {
    if (const auto* path = command.find(key); path && !path->string().empty()) {
      flag(name, path->string());
      if (std::string_view(key) == "_lut_path") {
        flag("--lut-input", value("lut_input").string()); flag("--lut-output", value("lut_output").string());
        flag("--lut-strength", fmt(value("lut_strength")));
      }
    }
  }
  if ((validated.encoding == OutputEncoding::Adaptive || validated.encoding == OutputEncoding::Pq || validated.encoding == OutputEncoding::Hlg) &&
      value("hevc_preset").string() == "medium") flag("--hevc-preset", "medium");
  if (model) for (auto name : {"--ai-brightness", "--ai-contrast", "--ai-shadows", "--ai-highlights", "--ai-hdr-range", "--ai-expansion-start"}) flag(name, fmt(cmd(name)));
  return args;
}

ConvertOptions request_options(const Value& request) {
  ConvertOptions options;
  const auto* command = request.find("command");
  bool panel_adapter = false;
  if (command) {
    if (const auto* adapter = command->find("adapter")) {
      if (!adapter->is_string() || adapter->string() != "panel-v1") {
        throw std::invalid_argument("unsupported edit options adapter");
      }
      panel_adapter = true;
    }
  }
  const auto settings = canonical_settings(request);
  apply_preset_document(settings, options);
  if (panel_adapter) {
    // Only normalize_options output follows the panel's three-decimal CLI
    // formatting. Direct canonical requests retain full schema precision.
    // Validate the original doubles above, then round before storing floats.
    const auto rounded_setting = [&](const char* key) {
      if (const auto* value = settings.find(key); value && value->is_number()) {
        const auto& setting = *find_setting_by_key(key);
        setting.apply(options, parse_setting_text(setting, fmt(*value)));
      }
    };
    for (const auto& [flag, key] : kCreativeFlags) rounded_setting(key);
    rounded_setting("headroom");
    rounded_setting("lut_strength");
  }
  const auto request_real = [&](const Value& value) {
    return static_cast<float>(panel_adapter ? std::stod(fmt(value)) : value.number());
  };
  if (command) {
    for (const auto& [key, value] : command->members()) {
      if (key == "input") options.input = path_from_utf8(value.string());
      else if (key == "output") options.output_directory = path_from_utf8(value.string());
      else if (key == "report") options.report_path = path_from_utf8(value.string());
      else if (key == "depth") {
        const auto depth = value.number();
        if (depth != 8 && depth != 10) throw std::invalid_argument("depth must be 8 or 10");
        options.depth = static_cast<int>(depth);
      } else if (key == "overwrite") options.overwrite = value.boolean();
      else if (key == "recursive") options.recursive = value.boolean();
      else if (key == "skip_existing") options.skip_existing = value.boolean();
      else if (key == "external_gain") options.external_gain_path = path_from_utf8(value.string());
      else if (key == "external_gain_report") options.external_gain_report = path_from_utf8(value.string());
      else if (key == "model_id") options.ai_model_path = path_from_utf8(value.string());
      else if (key == "_lut_path") options.color_lut.path = path_from_utf8(value.string());
      else if (key == "frame") {
        if (value.is_string()) {
          if (value.string().empty()) throw std::invalid_argument("frame: file path must not be empty");
          options.frame_spec_path = path_from_utf8(value.string());
        } else if (!value.is_null()) options.frame = parse_frame_spec(value);
      }
      else if (key == "--ai-brightness") options.ai_post.brightness_ev = request_real(value);
      else if (key == "--ai-contrast") options.ai_post.contrast = request_real(value);
      else if (key == "--ai-shadows") options.ai_post.shadows_ev = request_real(value);
      else if (key == "--ai-highlights") options.ai_post.highlights_stops = request_real(value);
      else if (key == "--ai-hdr-range") options.ai_post.hdr_range_stops = request_real(value);
      else if (key == "--ai-expansion-start") options.ai_post.expansion_start = request_real(value);
      else if (key != "model_mode" && key != "compact" && key != "region" && key != "adapter") throw std::invalid_argument("unknown command key: " + key);
    }
  }
  apply_render_defaults(options);
  return options;
}
PreviewRegion request_region(const Value& request) {
  PreviewRegion region;
  if (const auto* command = request.find("command")) if (const auto* item = command->find("region")) {
    const auto coordinate = [&](const char* key, std::optional<std::uint32_t>& out) {
      if (const auto* value = item->find(key)) {
        const auto n = value->number();
        if (n < 0 || n > UINT32_MAX || std::floor(n) != n) throw std::invalid_argument("invalid region coordinate");
        out = static_cast<std::uint32_t>(n);
      }
    };
    coordinate("left", region.left); coordinate("top", region.top);
    coordinate("width", region.width); coordinate("height", region.height);
    if (const auto* center = item->find("center")) region.center = center->boolean();
  }
  return region;
}

}  // namespace hyperdr
