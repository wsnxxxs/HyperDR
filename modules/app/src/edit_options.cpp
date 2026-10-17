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
  const auto encoding = get(edit, "encoding", text("adaptive"));
  const auto name = encoding.string();
  const bool sdr = name == "sdr-jpeg" || name == "sdr-tiff";
  const bool hlg = name == "hlg" || name == "avif-hlg";
  const auto output = get(edit, "outputGamut", text("auto"));
  if (output.string() != "auto" && output.string() != "srgb" && output.string() != "p3") {
    throw std::invalid_argument("outputGamut must be auto, srgb or p3");
  }
  const auto headroom = model ? number(hlg ? 2.3 : 2.5)
      : get(edit, "hdrRange", number(hlg ? 2.3 : 2.5));
  if (hlg && headroom.is_number() && headroom.number() > 2.3) {
    throw std::invalid_argument("HLG dynamic range cannot exceed 2.3 stops");
  }
  Object settings{
      {"encoding", encoding}, {"look", text("photographic")},
      {"color_gamut", get(edit, "colorGamut", text("srgb"))},
      {"clamp_srgb", sdr ? boolean(false) : get(edit, "clampSrgb", boolean(false))},
      {"highlight_recovery", get(edit, "highlightRecovery", text("blend"))},
      {"lut_input", get(edit, "lutInput", text("srgb"))},
      {"lut_output", get(edit, "lutOutput", text("srgb"))},
      {"lut_strength", get(edit, "lutStrength", number(1))},
      {"contrast", model ? number(1) : get(edit, "contrast", number(1))},
      {"vibrance", model ? number(0) : get(edit, "vibrance", number(0))},
      {"gain_strength", get(edit, "hdrStrength", number(model ? 1 : .4))},
      {"pop", number(0)}, {"headroom_max", headroom}, {"headroom", headroom},
      {"exposure", text("auto")},
      {"exposure_bias", model ? number(0) : get(edit, "brightness", number(.6))},
      {"expansion_start", model ? number(.25) : get(edit, "expansionStart", number(.25))},
      {"area_coverage", model ? number(1) : get(edit, "areaCoverage", number(1))},
      {"quality", get(edit, "quality", number(90))},
      {"hevc_preset", get(edit, "hevcPreset", text("slow"))}};
  if (sdr) settings.emplace("output_gamut", output);
  // Validate without converting doubles to the renderer's floats: the canonical
  // document must preserve the Python adapter's numbers exactly.
  for (const auto& [key, value] : settings) validate_setting_value(*find_setting_by_key(key), value);

  // Command metadata identifies adapter output without changing the canonical
  // renderer settings or the Python settings/argv golden documents.
  Object command{{"adapter", text("panel-v1")}};
  for (auto key : {"input", "output", "report", "external_gain", "external_gain_report",
      "_raw_profile_path", "_raw_look_path", "_lens_profile_path", "_lut_path"}) {
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
  command["color_explicit"] = boolean(edit.find("colorGamut") != nullptr);
  command["output_explicit"] = boolean(edit.find("outputGamut") != nullptr);
  const auto domain = get(edit, "sourceDomain", text("")).string();
  command["depth"] = number(name == "adaptive" && (domain == "display-referred-hdr" || domain == "dual-rendition")
      ? 10 : name == "adaptive" || name == "ultrahdr" || sdr ? 8 : 10);
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
          (hlg && std::string_view(post.key) == "aiHdrRange" && value.number() > 2.3)) {
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
  // A frame is an inline document here and a file on the command line; there
  // is no faithful argv for it, and dropping it would describe another export.
  if (const auto* frame = command.find("frame"); frame && !frame->is_null())
    throw std::invalid_argument("a framed request has no command-line form; write the frame to a file for --frame");
  std::vector<std::string> args{"HyperDR", "convert", cmd("input").string(), "--output", cmd("output").string(),
      "--encoding", value("encoding").string()};
  const auto flag = [&](const char* name, std::string val) { args.emplace_back(name); args.push_back(std::move(val)); };
  if (!model && !external) {
    flag("--look", value("look").string());
    for (const auto& [name, key] : kCreativeFlags) flag(name, fmt(value(key)));
    flag("--exposure", "auto");
    flag("--headroom", fmt(value("headroom")));
  } else flag("--gain-strength", fmt(value("gain_strength")));
  flag("--highlight-recovery", value("highlight_recovery").string());
  flag("--quality", fmt(value("quality")));
  flag("--depth", fmt(cmd("depth")));
  flag("--report", cmd("report").string());
  if (model) flag("--ai-model", cmd("model_id").string());
  if (external) {
    flag("--external-gain", cmd("external_gain").string());
    flag("--external-gain-report", cmd("external_gain_report").string());
  }
  if (cmd("color_explicit").boolean()) flag("--color-gamut", value("color_gamut").string());
  if (cmd("output_explicit").boolean() && is_sdr_encoding(validated.encoding)) flag("--output-gamut", value("output_gamut").string());
  if (value("clamp_srgb").boolean()) args.emplace_back("--clamp-srgb");
  for (const auto& [key, name] : {std::pair{"_raw_profile_path","--raw-profile"}, {"_raw_look_path","--raw-look"},
      {"_lens_profile_path","--raw-lens-profile"}, {"_lut_path","--lut"}}) {
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
      else if (key == "_raw_profile_path") options.raw.profile = path_from_utf8(value.string());
      else if (key == "_raw_look_path") options.raw.look_profile = path_from_utf8(value.string());
      else if (key == "_lens_profile_path") options.raw.lens_profile = path_from_utf8(value.string());
      else if (key == "_lut_path") options.color_lut.path = path_from_utf8(value.string());
      else if (key == "frame") {
        if (!value.is_null()) options.frame = parse_frame_spec(value);
      }
      else if (key == "--ai-brightness") options.ai_post.brightness_ev = request_real(value);
      else if (key == "--ai-contrast") options.ai_post.contrast = request_real(value);
      else if (key == "--ai-shadows") options.ai_post.shadows_ev = request_real(value);
      else if (key == "--ai-highlights") options.ai_post.highlights_stops = request_real(value);
      else if (key == "--ai-hdr-range") options.ai_post.hdr_range_stops = request_real(value);
      else if (key == "--ai-expansion-start") options.ai_post.expansion_start = request_real(value);
      else if (key != "model_mode" && key != "color_explicit" && key != "output_explicit" &&
               key != "compact" && key != "region" && key != "adapter") throw std::invalid_argument("unknown command key: " + key);
    }
  }
  // A profile may arrive in command rather than in the canonical settings.
  // Resolve its defaults after every path is known; explicit controls still win.
  apply_render_defaults(options, settings.find("contrast") != nullptr,
                         settings.find("vibrance") != nullptr);
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
