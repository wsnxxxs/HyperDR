#include "cli_commands.hpp"

#include "hyperdr/app/schema.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <cmath>

namespace hyperdr::app::detail {

float real(std::string_view text, const char* name) {
  try {
    std::size_t used = 0;
    const double value = std::stod(std::string(text), &used);
    if (used != text.size() || !std::isfinite(value)) throw std::invalid_argument("bad");
    return static_cast<float>(value);
  } catch (const std::exception&) {
    throw std::invalid_argument(std::string("invalid ") + name);
  }
}

std::string next_value(int& i, int argc, char** argv, std::string_view option) {
  if (++i >= argc) {
    throw std::invalid_argument(std::string(option) + " requires a value");
  }
  return argv[i];
}

// One parser for every command that accepts render settings, so `convert` and
// `curve` can never disagree about what a flag means or what it defaults to.
// Settings come from the schema; only the plumbing is listed here.
void parse_settings(int argc, char** argv, int first, ConvertOptions& options,
                    unsigned* curve_samples, PreviewRegion* region) {
  bool contrast_set = false, vibrance_set = false;
  for (int i = first; i < argc; ++i) {
    const std::string_view arg = argv[i];
    contrast_set = contrast_set || arg == "--contrast";
    vibrance_set = vibrance_set || arg == "--vibrance";
    if (const Setting* setting = find_setting_by_flag(arg)) {
      const std::string text = setting->kind == SettingKind::kBoolean
                                   ? std::string{}
                                   : next_value(i, argc, argv, arg);
      setting->apply(options, parse_setting_text(*setting, text));
      continue;
    }
    if (region && arg == "--detail-left") {
      region->left = integer<std::uint32_t>(next_value(i, argc, argv, arg), "detail left");
    } else if (region && arg == "--detail-top") {
      region->top = integer<std::uint32_t>(next_value(i, argc, argv, arg), "detail top");
    } else if (region && arg == "--detail-width") {
      region->width = integer<std::uint32_t>(next_value(i, argc, argv, arg), "detail width");
    } else if (region && arg == "--detail-height") {
      region->height = integer<std::uint32_t>(next_value(i, argc, argv, arg), "detail height");
    } else if (region && arg == "--detail-center") {
      region->center = true;
    } else if (arg == "--fast-preview" && curve_samples == nullptr) {
      // Intent is selected explicitly at the command boundary. The size option
      // remains a pure output bound, so it can also describe a full-quality
      // size-limited export and argument order cannot change this decision.
      options.decode_intent = DecodeIntent::Preview;
      options.raw.half_size = true;
    } else if (arg == "--samples" && curve_samples != nullptr) {
      *curve_samples = integer<unsigned>(next_value(i, argc, argv, arg), "sample count");
    } else if (arg == "--json" && curve_samples != nullptr) {
      // Accepted for symmetry with `inspect --json`; the curve is always JSON.
    } else if (arg == "--output") {
      options.output_directory = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--report") {
      options.report_path = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--external-gain") {
      options.external_gain_path = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--external-gain-report") {
      options.external_gain_report = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--allow-legacy-external-gain") {
      options.allow_legacy_external_gain = true;
    } else if (arg == "--ai-model") {
      // The value is a model id from the fixed table, not a path: the shipping
      // adapter owns the assets and never opens a caller-named file. The bare
      // flag stays accepted and still means the incumbent, so existing scripts
      // and saved settings keep behaving identically.
      if (i + 1 < argc && !std::string_view(argv[i + 1]).starts_with("--")) {
        options.ai_model_path = argv[++i];
      } else {
        options.ai_model_path = kEmbeddedNativeModel;
      }
    } else if (arg == "--ai-brightness") {
      options.ai_post.brightness_ev =
          real(next_value(i, argc, argv, arg), "AI brightness");
    } else if (arg == "--ai-contrast") {
      options.ai_post.contrast =
          real(next_value(i, argc, argv, arg), "AI contrast");
    } else if (arg == "--ai-shadows") {
      options.ai_post.shadows_ev =
          real(next_value(i, argc, argv, arg), "AI shadows");
    } else if (arg == "--ai-highlights") {
      options.ai_post.highlights_stops =
          real(next_value(i, argc, argv, arg), "AI highlights");
    } else if (arg == "--ai-hdr-range") {
      options.ai_post.hdr_range_stops =
          real(next_value(i, argc, argv, arg), "AI HDR range");
    } else if (arg == "--ai-expansion-start") {
      options.ai_post.expansion_start =
          real(next_value(i, argc, argv, arg), "AI expansion start");
    } else if (arg == "--input-tensor") {
      options.model_input_tensor = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--tensor-width") {
      options.model_input_tensor_width =
          integer<std::uint32_t>(next_value(i, argc, argv, arg), "tensor width");
    } else if (arg == "--tensor-height") {
      options.model_input_tensor_height =
          integer<std::uint32_t>(next_value(i, argc, argv, arg), "tensor height");
    } else if (arg == "--capture-json") {
      options.model_capture_path = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--decode-cache") {
      options.decode_cache_directory = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--decode-cache-source-sha256") {
      // Internal panel plumbing: uploads are hashed while streaming, so the
      // short-lived preview CLI need not read a large RAW again just to name an
      // already-decoded cache entry.
      options.decode_cache_source_sha256 = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-bad-pixels") {
      options.raw.bad_pixel_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-dark-frame") {
      options.raw.dark_frame = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--lut") {
      options.color_lut.path = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-linearization-lut") {
      options.raw.linearization_lut = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-lens-shading") {
      options.raw.lens_shading_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-auto-bad-pixels") {
      options.raw.auto_bad_pixel_correction = true;
    } else if (arg == "--raw-gain") {
      options.raw.digital_gain = real(next_value(i, argc, argv, arg), "RAW digital gain");
    } else {
      throw std::invalid_argument("unknown option: " + std::string(arg));
    }
  }
  if (!options.raw.profile.empty()) {
    // The profile already supplies its base look. Only explicit creative
    // controls should change it; argument order must not affect this choice.
    if (!contrast_set) options.gain.look.contrast = 1.0F;
    if (!vibrance_set) options.gain.look.vibrance = 0.0F;
  }
  if (is_hlg_encoding(options.encoding)) {
    // HLG's range above diffuse white is fixed by the standard, so a higher
    // ceiling cannot be honoured. Lowering it silently is right for the
    // automatic case; an explicit request above it is an error, reported by
    // validate_convert_options.
    options.gain.look.headroom_max_stops =
        std::min(options.gain.look.headroom_max_stops, kHlgHeadroomStops);
  }
}

}  // namespace hyperdr::app::detail
