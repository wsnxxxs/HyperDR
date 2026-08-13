#include "hyperdr/app/cli.hpp"

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/version.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/resample.hpp"

#include <algorithm>
#include <bit>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace hyperdr {
namespace {

void usage() {
  std::cout
      << "HyperDR " << kVersion
      << " - ARW/DNG/JPEG/PNG/HEIC/AVIF/Ultra HDR to Adaptive HDR, Ultra HDR,"
         " PQ, HLG, AVIF\n\n"
         "Usage:\n"
         "  HyperDR convert <file-or-directory> --output <directory> [options]\n"
         "  HyperDR inspect <file.heic> [--json]\n"
         "  HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]\n"
         "  HyperDR display-curve <reference.heic> <candidate.heic>\n"
         "                         --headroom <stops> [--headroom <stops> ...]\n"
         "  HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]\n"
         "                            [--quality <1..100>] [--half-size]\n"
         "                            [--highlight-recovery blend|reconstruct|clip|unclip]\n"
         "                            [--base-only]\n"
         "  HyperDR preview-frame <image> --output <preview.hpf> [look options]\n"
         "                            [--preview-max-edge <pixels>] [--fast-preview]\n"
         "  HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>\n"
         "                            [--long-side <pixels>] [--half-size] [look options]\n"
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
          "  --fast-preview                     Explicitly allow RAW half-size decoding\n"
          "  --raw-bad-pixels <file>             LibRaw bad-pixel coordinate map\n"
          "  --raw-dark-frame <file>              LibRaw dark-frame PGM\n"
          "  --raw-linearization-lut <file>      N code-to-code LUT for RAW linearization\n"
          "  --raw-lens-shading <file>           Text gain map: width height channels + gains\n";
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
    } else if (arg == "--raw-bad-pixels") {
      options.raw.bad_pixel_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-dark-frame") {
      options.raw.dark_frame = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-linearization-lut") {
      options.raw.linearization_lut = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-lens-shading") {
      options.raw.lens_shading_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-auto-bad-pixels") {
      options.raw.auto_bad_pixel_correction = true;
    } else if (arg == "--raw-gain") {
      options.raw.digital_gain = real(next_value(i, argc, argv, arg), "RAW digital gain");
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

int display_curve_command(int argc, char** argv) {
  if (argc < 5) {
    throw std::invalid_argument(
        "display-curve requires reference, candidate, and --headroom");
  }
  const std::filesystem::path reference = argv[2];
  const std::filesystem::path candidate = argv[3];
  std::vector<float> headrooms;
  for (int i = 4; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--headroom") {
      headrooms.push_back(real(next_value(i, argc, argv, arg),
                               "display headroom"));
    } else {
      throw std::invalid_argument("unknown display-curve option: " +
                                  std::string(arg));
    }
  }
  const auto result = compare_gain_map_heic_curve(reference, candidate, headrooms);
  std::cout << std::setprecision(10) << "{\"points\":[";
  for (std::size_t index = 0; index < result.points.size(); ++index) {
    if (index != 0) std::cout << ',';
    const auto& point = result.points[index];
    std::cout << "{\"headroom_stops\":" << point.headroom_stops
              << ",\"mae_linear_p3\":" << point.mae_linear_p3
              << ",\"mse_linear_p3\":" << point.mse_linear_p3
              << ",\"max_abs_error_linear_p3\":"
              << point.max_abs_error_linear_p3
              << ",\"total_values\":" << point.total_values
              << ",\"reference_clamp_values\":"
              << point.reference_clamp_values
              << ",\"candidate_clamp_values\":"
              << point.candidate_clamp_values
              << ",\"total_pixels\":" << point.total_pixels
              << ",\"reference_clamp_pixels\":"
              << point.reference_clamp_pixels
              << ",\"candidate_clamp_pixels\":"
              << point.candidate_clamp_pixels << '}';
  }
  std::cout << "]}\n";
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
  bool model_input = false;
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
    } else if (arg == "--model-input") {
      model_input = true;
    } else if (arg == "--raw-bad-pixels") {
      raw.bad_pixel_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-dark-frame") {
      raw.dark_frame = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-linearization-lut") {
      raw.linearization_lut = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-lens-shading") {
      raw.lens_shading_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-auto-bad-pixels") {
      raw.auto_bad_pixel_correction = true;
    } else if (arg == "--raw-gain") {
      raw.digital_gain = real(next_value(i, argc, argv, arg), "RAW digital gain");
    } else {
      throw std::invalid_argument("unknown thumbnail option: " + std::string(arg));
    }
  }
  if (output.empty()) throw std::invalid_argument("thumbnail --output is required");
  const std::filesystem::path input = argv[2];
  if (same_path(input, output)) {
    throw std::invalid_argument("thumbnail output must differ from input image");
  }
  const auto preview =
      encode_preview_jpeg(input, max_edge, quality, raw, model_input);
  write_binary_file_atomic(output, preview.bytes, true);
  // The JPEG alone is not the whole answer for an HDR input: it holds the
  // picture divided by `scale`, and a viewer that multiplies back by it sees the
  // highlights the file actually contains instead of a clipped white. Reported
  // on stdout as JSON for the same reason `curve` and `schema` are -- the file
  // is the output, so anything about it belongs in the stream beside it. RAW
  // also reports the automatic scene exposure that the browser must apply
  // before the user's brightness bias.
  std::cout << "{\"scale\":" << preview.scale
            << ",\"exposure\":" << preview.exposure_ev << "}\n";
  return 0;
}

void append_u32_le(std::vector<std::uint8_t>& bytes, std::uint32_t value) {
  bytes.push_back(static_cast<std::uint8_t>(value));
  bytes.push_back(static_cast<std::uint8_t>(value >> 8U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 16U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 24U));
}

void append_float_image(std::vector<std::uint8_t>& bytes,
                        const FloatImage& image) {
  bytes.reserve(bytes.size() + image.pixels.size() * sizeof(float));
  for (const float value : image.pixels) {
    if (!std::isfinite(value)) {
      throw std::runtime_error("native preview contains a non-finite pixel");
    }
    append_u32_le(bytes, std::bit_cast<std::uint32_t>(value));
  }
}

std::vector<std::uint8_t> native_preview_packet(const GainMapResult& result,
                                                const DecodeInfo& decode) {
  // Wire format v1: magic, JSON byte length, UTF-8 JSON, then two tightly
  // packed little-endian HWC RGB float32 planes (SDR base, reconstructed HDR).
  // JSON makes status/geometry extensible while the pixel payload stays
  // directly uploadable to GPU textures without an 8-bit colour conversion.
  auto hdr = reconstruct_gain_map(result.base_linear, result.gain_map,
                                  result.metadata, result.headroom_stops);
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.native-preview/v1")
      .member("width", result.base_linear.width)
      .member("height", result.base_linear.height)
      .member("channels", 3)
      .member("layout", "HWC")
      .member("sampleType", "float32-le")
      .member("colorSpace", "linear-display-p3")
      .member("relativeSdrWhite", 1.0F)
      .member("headroomStops", result.headroom_stops)
      .member("status", decode.degraded ? "degraded" : "ok")
      .begin_array("degradationReasons");
  for (const auto& reason : decode.degradation_reasons) writer.element(reason);
  writer.end_array().end_object();
  const std::string metadata = writer.take();

  std::vector<std::uint8_t> bytes{
      'H', 'Y', 'P', 'R', 'E', 'V', '1', '\n'};
  append_u32_le(bytes, static_cast<std::uint32_t>(metadata.size()));
  bytes.insert(bytes.end(), metadata.begin(), metadata.end());
  append_float_image(bytes, result.base_linear);
  append_float_image(bytes, hdr);
  return bytes;
}

int preview_frame_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("preview-frame requires one input image");
  ConvertOptions options;
  options.input = argv[2];
  parse_settings(argc, argv, 3, options);
  if (options.output_directory.empty()) {
    throw std::invalid_argument("preview-frame --output is required");
  }
  if (options.preview_max_edge == 0) options.preview_max_edge = 2048;
  if (same_path(options.input, options.output_directory)) {
    throw std::invalid_argument("preview-frame output must differ from input image");
  }
  validate_gain_map_options(options.gain);
  options.raw.ignore_embedded_gain_map = !options.external_gain_path.empty();
  auto decoded = decode_image(options.input, options.raw);
  decoded.linear_p3 = resample_to_max_edge(
      std::move(decoded.linear_p3), options.preview_max_edge);
  GainMapResult result;
  if (!options.external_gain_path.empty()) {
    auto external = read_external_gain_map(
        options.external_gain_path, options.external_gain_report,
        options.allow_legacy_external_gain);
    const auto development = replay_external_development(
        external, options.input, decoded, options);
    result = make_external_gain_map(decoded.linear_p3, std::move(external),
                                    development, decoded.capture,
                                    decoded.describe_input());
  } else {
    result = render_decoded_image(decoded, options.gain);
  }
  validate_encoding_headroom(options.encoding, result.headroom_stops);
  write_binary_file_atomic(options.output_directory,
                           native_preview_packet(result, decoded.decode), true);
  return 0;
}

std::pair<std::uint32_t, std::uint32_t> model_tensor_size(
    std::uint32_t width, std::uint32_t height, std::uint32_t long_side) {
  if (width == 0 || height == 0 || long_side < 16 || long_side > 8192) {
    throw std::invalid_argument("invalid model input dimensions");
  }
  const double scale = std::min(
      1.0, static_cast<double>(long_side) / std::max(width, height));
  const auto align = [](std::uint32_t value) {
    return std::max<std::uint32_t>(16, ((value + 15U) / 16U) * 16U);
  };
  const auto scaled_width = std::max<std::uint32_t>(
      1, static_cast<std::uint32_t>(std::lround(width * scale)));
  const auto scaled_height = std::max<std::uint32_t>(
      1, static_cast<std::uint32_t>(std::lround(height * scale)));
  return {align(scaled_width), align(scaled_height)};
}

std::vector<std::uint8_t> float32_le_bytes(const FloatImage& image) {
  std::vector<std::uint8_t> bytes(image.pixels.size() * sizeof(float));
  for (std::size_t index = 0; index < image.pixels.size(); ++index) {
    const float value = image.pixels[index];
    if (!std::isfinite(value) || value < 0.0F || value > 1.0F) {
      throw std::runtime_error("developed model input is outside linear SDR [0,1]");
    }
    const auto bits = std::bit_cast<std::uint32_t>(value);
    const auto offset = index * 4U;
    bytes[offset] = static_cast<std::uint8_t>(bits);
    bytes[offset + 1] = static_cast<std::uint8_t>(bits >> 8U);
    bytes[offset + 2] = static_cast<std::uint8_t>(bits >> 16U);
    bytes[offset + 3] = static_cast<std::uint8_t>(bits >> 24U);
  }
  return bytes;
}

std::string model_input_report(const std::filesystem::path& input,
                               const std::filesystem::path& output,
                               const DecodedImage& decoded,
                               const GainMapResult& developed,
                               const GainMapOptions& gain,
                               const RawDecodeOptions& raw,
                               const FloatImage& tensor) {
  const auto& d = decoded.decode;
  json::Writer writer(json::Writer::Style::kIndented);
  writer.begin_object()
      .member("schema", "hyperdr.model-input/v1")
      .member("source", path_utf8(input))
      .member("source_sha256", sha256_file_hex(input))
      .member("highlight_recovery", highlight_recovery_name(raw.highlight_recovery))
      .member("orientation", decoded.metadata.orientation)
      .begin_array("sensor_size").element(d.sensor_width).element(d.sensor_height).end_array()
      .begin_array("requested_crop").element(d.target_width).element(d.target_height).end_array()
      .begin_array("delivered_crop").element(d.decoded_width).element(d.decoded_height).end_array()
      .begin_array("requested_crop_origin_sensor")
          .element(d.requested_crop_left).element(d.requested_crop_top).end_array()
      .begin_array("delivered_crop_origin_sensor")
          .element(d.delivered_crop_left).element(d.delivered_crop_top).end_array()
      .member("raw_half_size", raw.half_size)
      .member("default_crop_present", d.default_crop_present)
      .member("requested_crop_applied", d.target_dimensions_applied)
      .begin_object("development_recipe")
      .member("id", "photographic-v1")
      .member("exposure_bias_ev", gain.exposure_bias_ev)
      .member("exposure_ev", developed.exposure_ev)
      .member("headroom_stops", developed.stats.headroom_stops)
      .member("contrast", gain.look.contrast)
      .member("vibrance", gain.look.vibrance)
      .member("pop", gain.look.pop)
      .member("toe_end", gain.look.toe_end)
      .member("toe_output_ratio", gain.look.toe_output_ratio)
      .member("shoulder_start", gain.look.shoulder_start)
      .member("positive_exposure_limit_ev", gain.look.positive_exposure_limit_ev)
      .member("diffuse_gain_floor", gain.look.diffuse_gain_floor)
      .end_object()
      .begin_object("geometry")
      .begin_array("developed_size").element(developed.base_linear.width)
          .element(developed.base_linear.height).end_array()
      .begin_array("model_tensor_size").element(tensor.width).element(tensor.height).end_array()
      .member("resize_convention", "half-pixel-centres/area-then-bilinear")
      .member("model_stride", 16)
      .end_object()
      .begin_object("pixel_file")
      .member("path", path_utf8(output))
      .member("format", "raw_float32")
      .member("endianness", "little")
      .member("layout", "HWC")
      .member("color_space", "linear Display P3")
      .member("relative_sdr_white", 1.0F)
      .member("width", tensor.width)
      .member("height", tensor.height)
      .member("channels", tensor.channels)
      .member("byte_length", tensor.pixels.size() * sizeof(float))
      .member("sha256", sha256_file_hex(output))
      .end_object()
      .end_object();
  return writer.take() + "\n";
}

int model_input_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("model-input requires one input image");
  ConvertOptions options;
  std::filesystem::path output;
  std::filesystem::path report;
  std::uint32_t long_side = 1024;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (const Setting* setting = find_setting_by_flag(arg)) {
      const std::string text = setting->kind == SettingKind::kBoolean
                                   ? std::string{}
                                   : next_value(i, argc, argv, arg);
      setting->apply(options, parse_setting_text(*setting, text));
    } else if (arg == "--output") {
      output = next_value(i, argc, argv, arg);
    } else if (arg == "--report") {
      report = next_value(i, argc, argv, arg);
    } else if (arg == "--long-side") {
      long_side = integer<std::uint32_t>(next_value(i, argc, argv, arg),
                                         "model long side");
    } else if (arg == "--half-size") {
      options.raw.half_size = true;
    } else {
      throw std::invalid_argument("unknown model-input option: " + std::string(arg));
    }
  }
  if (output.empty() || report.empty()) {
    throw std::invalid_argument("model-input requires --output and --report");
  }
  const std::filesystem::path input = argv[2];
  if (same_path(input, output) || same_path(input, report) || same_path(output, report)) {
    throw std::invalid_argument("model-input source, pixels and report must be distinct");
  }
  validate_gain_map_options(options.gain);
  options.raw.ignore_embedded_gain_map = true;
  auto decoded = decode_image(input, options.raw);
  // The SDR base is developed before any model resampling.  This is the same
  // make_gain_map call used by final export; only its generated gain grid is
  // discarded here.
  auto development_options = options.gain;
  // Model labels are SDR development inputs, so the creative offset is pinned
  // rather than inherited: a recipe recorded here has to stay reproducible even
  // if the CLI's own default ever moves again.
  development_options.exposure_bias_ev = 0.0F;
  development_options.gain_strength = 1.0F;
  // The domain still comes from the decode. With embedded gain maps ignored
  // above, a gain-map container arrives as its display-referred SDR base, which
  // is exactly the developed image a model label wants; a RAW arrives
  // scene-referred and is developed by the photographic renderer as before.
  auto developed = make_gain_map(decoded.linear_p3, development_options,
                                 decoded.capture, decoded.describe_input());
  const auto [width, height] = model_tensor_size(
      developed.base_linear.width, developed.base_linear.height, long_side);
  auto tensor = resample_to(developed.base_linear, width, height);
  write_binary_file_atomic(output, float32_le_bytes(tensor), true);
  write_text_file_atomic(report,
                         model_input_report(input, output, decoded, developed,
                                            development_options, options.raw, tensor),
                         true);
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
  if (command == "display-curve") return display_curve_command(argc, argv);
  if (command == "inspect") return inspect_command(argc, argv);
  if (command == "verify") return verify_command(argc, argv);
  if (command == "thumbnail") return thumbnail_command(argc, argv);
  if (command == "preview-frame") return preview_frame_command(argc, argv);
  if (command == "model-input") return model_input_command(argc, argv);
  throw std::invalid_argument("unknown command: " + std::string(command));
}

}  // namespace hyperdr
