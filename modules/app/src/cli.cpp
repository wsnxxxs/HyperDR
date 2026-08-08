#include "hyperdr/app/cli.hpp"

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/version.hpp"

#include <algorithm>
#include <charconv>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>

namespace hyperdr {
namespace {

void usage() {
  std::cout
      << "HyperDR " << kVersion
      << " - ARW/DNG/JPEG/PNG/HEIC/Ultra HDR to Adaptive HDR, Ultra HDR, PQ, HLG, AVIF\n\n"
         "Usage:\n"
         "  HyperDR convert <file-or-directory> --output <directory> [options]\n"
         "  HyperDR inspect <file.heic> [--json]\n"
         "  HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]\n"
         "  HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]\n"
         "                            [--quality <1..100>] [--half-size]\n"
         "                            [--highlight-recovery blend|reconstruct|clip|unclip]\n"
         "                            [--base-only]\n"
         "  HyperDR curve [look options] [--samples <N>]   Emit the tone curve as JSON\n"
         "  HyperDR schema                                 Emit the settings schema as JSON\n\n"
         "Convert settings:\n"
      << settings_usage_text()
      << "\nConvert plumbing:\n"
         "  --output <directory>               Where converted images are written\n"
         "  --report <file.json>               Write a structured run report\n"
         "  --external-gain <file.f32>         Use an external canonical gain grid\n"
         "  --external-gain-report <file.json> Required sidecar for that gain grid\n"
         "  --allow-legacy-external-gain      Allow frozen v1 normalized sidecars\n"
         "  --decode-cache <directory>         Reuse decoded buffers across look-only reruns\n"
         "  --fast-preview                     Explicitly allow RAW half-size decoding\n";
  if (!kCodecsAvailable) {
    std::cout << "\nThis build was configured with HYPERDR_WITH_CODECS=OFF: the renderer\n"
                 "and its self-tests are present, but no format can be read or written.\n";
  }
}

template <class T>
T integer(std::string_view text, const char* name) {
  T value{};
  const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
    throw std::invalid_argument(std::string("invalid ") + name);
  }
  return value;
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
                    unsigned* curve_samples = nullptr) {
  for (int i = first; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (const Setting* setting = find_setting_by_flag(arg)) {
      const std::string text = setting->kind == SettingKind::kBoolean
                                   ? std::string{}
                                   : next_value(i, argc, argv, arg);
      setting->apply(options, parse_setting_text(*setting, text));
      continue;
    }
    if (arg == "--fast-preview" && curve_samples == nullptr) {
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
      options.output_directory = next_value(i, argc, argv, arg);
    } else if (arg == "--report") {
      options.report_path = next_value(i, argc, argv, arg);
    } else if (arg == "--external-gain") {
      options.external_gain_path = next_value(i, argc, argv, arg);
    } else if (arg == "--external-gain-report") {
      options.external_gain_report = next_value(i, argc, argv, arg);
    } else if (arg == "--allow-legacy-external-gain") {
      options.allow_legacy_external_gain = true;
    } else if (arg == "--decode-cache") {
      options.decode_cache_directory = next_value(i, argc, argv, arg);
    } else {
      throw std::invalid_argument("unknown option: " + std::string(arg));
    }
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

int convert_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("convert requires an input path");
  ConvertOptions options;
  options.input = argv[2];
  parse_settings(argc, argv, 3, options);
  return run_conversion(options);
}

// Emits the exporter's own global curve so the panel can render a preview from
// it rather than from a second, hand-written approximation of the same maths.
int curve_command(int argc, char** argv) {
  ConvertOptions options;
  unsigned samples = 257;
  parse_settings(argc, argv, 2, options, &samples);
  std::cout << look_curve_json(options.gain, samples) << '\n';
  return 0;
}

int schema_command(int argc, char** argv) {
  for (int i = 2; i < argc; ++i) {
    if (std::string_view(argv[i]) != "--json") {
      throw std::invalid_argument("unknown schema option: " + std::string(argv[i]));
    }
  }
  std::cout << schema_json();
  return 0;
}

void print_inspection(const HeifInspection& i) {
  std::cout << "structurally valid: " << (i.structurally_valid ? "yes" : "no") << '\n'
            << "HEIC brand: " << (i.has_heic_brand ? "yes" : "no") << '\n'
            << "TMAP brand/item: " << (i.has_tmap_brand ? "yes" : "no") << '/'
            << (i.has_tmap_item ? "yes" : "no") << '\n'
            << "dimg/altr: " << (i.has_dimg_reference ? "yes" : "no") << '/'
            << (i.has_altr_group ? "yes" : "no") << '\n'
            << "primary item: " << i.primary_item_id << '\n';
  for (const auto& error : i.errors) std::cout << "error: " << error << '\n';
  for (const auto& box : i.boxes) {
    std::cout << std::string(box.depth * 2, ' ') << box.type << " @" << box.offset
              << " (" << box.size << ")\n";
  }
}

int inspect_command(int argc, char** argv) {
  if (argc < 3 || argc > 4) throw std::invalid_argument("inspect requires one HEIC path");
  const auto inspection = inspect_heif(read_binary_file(argv[2]));
  if (argc == 4) {
    if (std::string_view(argv[3]) != "--json") {
      throw std::invalid_argument("unknown inspect option: " + std::string(argv[3]));
    }
    std::cout << inspection_json(inspection) << '\n';
  } else {
    print_inspection(inspection);
  }
  return inspection.structurally_valid ? 0 : 1;
}

int verify_command(int argc, char** argv) {
  if (argc < 3) {
    throw std::invalid_argument("verify requires one HEIC or Ultra HDR JPEG path");
  }
  const std::filesystem::path input = argv[2];
  std::filesystem::path reconstruct;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--reconstruct") reconstruct = next_value(i, argc, argv, arg);
    else throw std::invalid_argument("unknown verify option: " + std::string(arg));
  }

  const auto extension = lower_extension(input);
  if (extension == ".jpg" || extension == ".jpeg") {
    if (!reconstruct.empty()) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    verify_ultrahdr_jpeg(read_binary_file(input));
    std::cout << "Ultra HDR JPEG/R: yes\nverification passed\n";
    return 0;
  }

  const auto inspection = inspect_heif(read_binary_file(input));
  const bool adaptive = inspection.has_tmap_brand || inspection.has_tmap_item;
  const bool adaptive_valid =
      !adaptive || (inspection.has_tmap_brand && inspection.has_tmap_item &&
                    inspection.has_dimg_reference && inspection.has_altr_group);
  print_inspection(inspection);
  if (!(inspection.structurally_valid && inspection.has_heic_brand && adaptive_valid)) {
    std::cout << "verification failed\n";
    return 1;
  }
  if (!reconstruct.empty()) {
    if (!adaptive) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    if (same_path(input, reconstruct)) {
      throw std::invalid_argument("reconstruction output must differ from input HEIC");
    }
    reconstruct_heic_to_tiff(input, reconstruct);
    std::cout << "reconstructed preview: " << path_utf8(reconstruct) << '\n';
  } else {
    verify_heic_decodable(input);
    std::cout << (adaptive ? "base/Gain Map decode: passed\n"
                           : "BT.2100 HDR decode: passed\n");
  }
  std::cout << "verification passed\n";
  return 0;
}

int thumbnail_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("thumbnail requires one input image");
  std::filesystem::path output;
  std::uint32_t max_edge = 2048;
  int quality = 85;
  // A preview that ignores the RAW decode settings is a preview of a different
  // photograph, so the caller passes the ones it is about to convert with.
  RawDecodeOptions raw;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--output") output = next_value(i, argc, argv, arg);
    else if (arg == "--max-edge") {
      max_edge = integer<std::uint32_t>(next_value(i, argc, argv, arg), "preview max edge");
    } else if (arg == "--quality") {
      quality = integer<int>(next_value(i, argc, argv, arg), "preview quality");
      if (quality < 1 || quality > 100) {
        throw std::invalid_argument("preview quality must be in [1,100]");
      }
    } else if (arg == "--highlight-recovery") {
      const std::string name(next_value(i, argc, argv, arg));
      const auto mode = highlight_recovery_from_name(name);
      if (!mode) throw std::invalid_argument("unknown highlight recovery: " + name);
      raw.highlight_recovery = *mode;
    } else if (arg == "--half-size") {
      // The preview is bounded by --max-edge anyway, so half-size demosaic
      // costs nothing visible and roughly quarters the decode.
      raw.half_size = true;
    } else if (arg == "--base-only") {
      raw.ignore_embedded_gain_map = true;
    } else {
      throw std::invalid_argument("unknown thumbnail option: " + std::string(arg));
    }
  }
  if (output.empty()) throw std::invalid_argument("thumbnail --output is required");
  const std::filesystem::path input = argv[2];
  if (same_path(input, output)) {
    throw std::invalid_argument("thumbnail output must differ from input image");
  }
  write_binary_file_atomic(output, encode_preview_jpeg(input, max_edge, quality, raw), true);
  return 0;
}

}  // namespace

int run_cli(int argc, char** argv) {
  if (argc < 2 || std::string_view(argv[1]) == "--help" ||
      std::string_view(argv[1]) == "-h") {
    usage();
    return argc < 2 ? 2 : 0;
  }
  const std::string_view command = argv[1];
  if (command == "convert") return convert_command(argc, argv);
  if (command == "curve") return curve_command(argc, argv);
  if (command == "schema") return schema_command(argc, argv);
  if (command == "inspect") return inspect_command(argc, argv);
  if (command == "verify") return verify_command(argc, argv);
  if (command == "thumbnail") return thumbnail_command(argc, argv);
  throw std::invalid_argument("unknown command: " + std::string(command));
}

}  // namespace hyperdr
