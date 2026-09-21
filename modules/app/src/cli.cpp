#include "hyperdr/image/dcp_profile.hpp"
#include "hyperdr/app/cli.hpp"

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/preview.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/app/analysis_cache.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/availability.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/inspect.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/version.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/gainmap/reconstruct.hpp"
#include "hyperdr/image/fidelity.hpp"
#include "hyperdr/image/resample.hpp"

#include <algorithm>
#include <bit>
#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>
#include <memory>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

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
         "  HyperDR raw-metadata <raw-file>\n"
         "  HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]\n"
         "                         [--reference <source-image>]\n"
         "  HyperDR display-curve <reference.heic> <candidate.heic>\n"
         "                         --headroom <stops> [--headroom <stops> ...]\n"
         "  HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]\n"
         "                            [--quality <1..100>] [--half-size]\n"
         "                            [--highlight-recovery blend|reconstruct|clip|unclip]\n"
         "                            [--base-only]\n"
         "  HyperDR preview-frame <image> --output <preview.hpf> [look options]\n"
         "                            [--preview-max-edge <pixels>] [--fast-preview]\n"
         "  HyperDR model-gain <image> --ai-model [<id>] [look options]\n"
         "                            (writes a binary gain packet to stdout)\n"
         "                            [--input-tensor <linear-p3.f32> --tensor-width <px>\n"
         "                             --tensor-height <px>]\n"
         "  HyperDR model-list [--json]                    Emit the model table as JSON\n"
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
         "  --ai-model [<id>]                   Run an embedded native gain model\n"
         "                                     (research-cnn-v1,\n"
         "                                      research-exif-v1; default research-cnn-v1)\n"
         "  --input-tensor <file.f32>          Feed model-gain a developed HWC linear-P3\n"
         "                                     float32 tensor instead of decoding an image\n"
         "  --tensor-width <pixels>            Width of --input-tensor (required with it)\n"
         "  --tensor-height <pixels>           Height of --input-tensor (required with it)\n"
         "  --ai-brightness <EV>               Post-model SDR brightness\n"
         "  --ai-contrast <slope>              Post-model contrast around diffuse white\n"
         "  --ai-shadows <EV>                  Post-model shadow lift\n"
         "  --ai-highlights <stops>            Post-model highlight gain adjustment\n"
         "  --ai-hdr-range <stops>             Post-model gain-range cap\n"
         "  --ai-expansion-start <0..1>        Post-model gain luma knee\n"
          "  --allow-legacy-external-gain      Allow frozen v1 normalized sidecars\n"
          "  --decode-cache <directory>         Reuse decoded buffers across look-only reruns\n"
          "  --fast-preview                     Explicitly allow RAW half-size decoding\n"
          "  --raw-bad-pixels <file>             Visible-area bad-pixel coordinates\n"
          "  --raw-dark-frame <file>              Visible-area 16-bit dark-frame PGM\n"
          "  --lut <file.cube>                  Creative 1D/3D colour LUT\n"
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
      options.model_input_tensor = next_value(i, argc, argv, arg);
    } else if (arg == "--tensor-width") {
      options.model_input_tensor_width =
          integer<std::uint32_t>(next_value(i, argc, argv, arg), "tensor width");
    } else if (arg == "--tensor-height") {
      options.model_input_tensor_height =
          integer<std::uint32_t>(next_value(i, argc, argv, arg), "tensor height");
    } else if (arg == "--capture-json") {
      options.model_capture_path = next_value(i, argc, argv, arg);
    } else if (arg == "--decode-cache") {
      options.decode_cache_directory = next_value(i, argc, argv, arg);
    } else if (arg == "--decode-cache-source-sha256") {
      // Internal panel plumbing: uploads are hashed while streaming, so the
      // short-lived preview CLI need not read a large RAW again just to name an
      // already-decoded cache entry.
      options.decode_cache_source_sha256 = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-bad-pixels") {
      options.raw.bad_pixel_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-dark-frame") {
      options.raw.dark_frame = next_value(i, argc, argv, arg);
    } else if (arg == "--lut") {
      options.color_lut.path = next_value(i, argc, argv, arg);
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

// What a viewer of `candidate` sees compared with `reference`, both decoded the
// way every other command decodes them: a gain map is applied at its full
// alternate headroom and PQ/HLG are read through their exact inverses, so an
// HDR source and its gain-map conversion meet in the same linear P3 space.
void print_fidelity(const std::filesystem::path& reference,
                    const std::filesystem::path& candidate) {
  if (same_path(reference, candidate)) {
    throw std::invalid_argument("--reference must name a different file");
  }
  const RawDecodeOptions decode{};
  auto source = decode_image(reference, decode);
  auto converted = decode_image(candidate, decode);
  const auto result = measure_hdr_fidelity(source.linear_p3, converted.linear_p3);
  const auto stops = [](float peak) { return std::log2(std::max(peak, 1.0e-6F)); };
  const auto flags = std::cout.flags();
  const auto precision = std::cout.precision();
  std::cout << std::fixed << std::setprecision(3)
            << "reference: " << path_utf8(reference) << " ("
            << input_domain_name(source.domain) << ")\n"
            << "candidate domain: " << input_domain_name(converted.domain) << '\n'
            << "compared pixels: " << result.pixels << '\n'
            << "delta E ITP mean/p50/p95/p99/p99.9/max: " << result.delta_e_itp_mean
            << " / " << result.delta_e_itp_p50 << " / " << result.delta_e_itp_p95
            << " / " << result.delta_e_itp_p99 << " / " << result.delta_e_itp_p999
            << " / " << result.delta_e_itp_max << '\n'
            << "pixels above delta E ITP 1/2/5: " << 100.0 * result.fraction_above_1
            << "% / " << 100.0 * result.fraction_above_2 << "% / "
            << 100.0 * result.fraction_above_5 << "%\n"
            << "delta E ITP mean in shadows/midtones/highlights: "
            << result.band_delta_e_itp_mean[0] << " / " << result.band_delta_e_itp_mean[1]
            << " / " << result.band_delta_e_itp_mean[2] << " (pixels "
            << result.band_pixels[0] << " / " << result.band_pixels[1] << " / "
            << result.band_pixels[2] << ")\n"
            << "PSNR (PQ, BT.2020): ";
  if (std::isinf(result.psnr_pq_db)) std::cout << "identical\n";
  else std::cout << result.psnr_pq_db << " dB\n";
  std::cout << "peak luminance reference/candidate: " << result.reference_peak << " ("
            << stops(result.reference_peak) << " stops) / " << result.candidate_peak << " ("
            << stops(result.candidate_peak) << " stops)\n"
            << "mean luminance reference/candidate: " << result.reference_mean << " / "
            << result.candidate_mean << '\n';
  // The same comparison after averaging 4x4 blocks in linear light. Per-pixel
  // ΔE ITP counts the dither grain of an 8-bit base in the deepest shadows as
  // colour error at full weight, although no display shows a camera frame at
  // 1:1 and grain that fine averages out before anyone sees it. The quarter
  // scale is still larger than any screen the photograph is viewed on; a tonal
  // or colour shift survives the averaging and grain does not, which is the
  // distinction the full-resolution figures above cannot make.
  constexpr std::uint32_t kViewingScale = 4;
  const auto width = source.linear_p3.width / kViewingScale;
  const auto height = source.linear_p3.height / kViewingScale;
  if (width >= 256 && height >= 256) {
    const auto viewed = measure_hdr_fidelity(
        resample_to(std::move(source.linear_p3), width, height),
        resample_to(std::move(converted.linear_p3), width, height));
    std::cout << "at 1/" << kViewingScale << " scale (" << width << 'x' << height
              << ", 4x4 linear means) delta E ITP mean/p99/p99.9: "
              << viewed.delta_e_itp_mean << " / " << viewed.delta_e_itp_p99 << " / "
              << viewed.delta_e_itp_p999 << ", shadows/midtones/highlights: "
              << viewed.band_delta_e_itp_mean[0] << " / " << viewed.band_delta_e_itp_mean[1]
              << " / " << viewed.band_delta_e_itp_mean[2] << ", PSNR: ";
    if (std::isinf(viewed.psnr_pq_db)) std::cout << "identical\n";
    else std::cout << viewed.psnr_pq_db << " dB\n";
  }
  std::cout.flags(flags);
  std::cout.precision(precision);
}

int verify_command(int argc, char** argv) {
  if (argc < 3) {
    throw std::invalid_argument("verify requires one HEIC or JPEG path");
  }
  const std::filesystem::path input = argv[2];
  std::filesystem::path reconstruct;
  std::filesystem::path reference;
  for (int i = 3; i < argc; ++i) {
    const std::string_view arg = argv[i];
    if (arg == "--reconstruct") reconstruct = next_value(i, argc, argv, arg);
    else if (arg == "--reference") reference = next_value(i, argc, argv, arg);
    else throw std::invalid_argument("unknown verify option: " + std::string(arg));
  }

  const auto extension = lower_extension(input);
  if (extension == ".jpg" || extension == ".jpeg") {
    if (!reconstruct.empty()) {
      throw std::invalid_argument("--reconstruct is only available for gain-map HEIC");
    }
    if (is_ultrahdr_jpeg_file(input)) {
      verify_ultrahdr_jpeg(read_binary_file(input));
      std::cout << "Ultra HDR JPEG/R: yes\n";
    } else {
      verify_sdr_jpeg(read_binary_file(input));
      std::cout << "SDR JPEG: yes\n";
    }
    if (!reference.empty()) print_fidelity(reference, input);
    std::cout << "verification passed\n";
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
  if (!reference.empty()) print_fidelity(reference, input);
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
    } else if (arg == "--raw-profile") {
      raw.profile = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-lens-profile") {
      raw.lens_profile = path_from_utf8(next_value(i, argc, argv, arg));
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
  static_assert(sizeof(float) == 4 && std::endian::native == std::endian::little);
  const auto offset = bytes.size();
  bytes.resize(offset + image.pixels.size() * sizeof(float));
  const auto row_size = static_cast<std::size_t>(image.width) * image.channels;
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    const auto* row = image.pixels.data() + static_cast<std::size_t>(y) * row_size;
    if (!std::all_of(row, row + row_size, [](float value) { return std::isfinite(value); }))
      throw std::runtime_error("native preview contains a non-finite pixel");
    std::memcpy(bytes.data() + offset + static_cast<std::size_t>(y) * row_size * sizeof(float),
                row, row_size * sizeof(float));
  });
}

std::vector<std::uint8_t> photo_preview_packet(const PhotoRenditions& result,
                                                const DecodeInfo& decode,
                                                const InputDescription& input, bool hasCaptureMetadata) {
  // Wire format v1: magic, JSON byte length, UTF-8 JSON, then two tightly
  // packed little-endian HWC RGB float32 planes (SDR base, reconstructed HDR).
  // JSON makes status/geometry extensible while the pixel payload stays
  // directly uploadable to GPU textures without an 8-bit colour conversion.
  const auto& hdr = result.hdr.pixels.empty() ? result.sdr : result.hdr;
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.native-preview/v1")
      .member("width", result.sdr.width)
      .member("height", result.sdr.height)
      .member("channels", 3)
      .member("layout", "HWC")
      .member("sampleType", "float32-le")
      .member("colorSpace", "linear-display-p3")
      .member("relativeSdrWhite", 1.0F)
      .member("headroomStops", result.stats.headroom_stops)
      .member("inputDomain", input_domain_name(input.domain))
      .member("hasCaptureMetadata", hasCaptureMetadata)
      .member("inputHeadroomStops", std::log2(input.headroom))
      .member("status", decode.degraded ? "degraded" : "ok")
      .begin_array("degradationReasons");
  for (const auto& reason : decode.degradation_reasons) writer.element(reason);
  writer.end_array().end_object();
  const std::string metadata = writer.take();

  std::vector<std::uint8_t> bytes{
      'H', 'Y', 'P', 'R', 'E', 'V', '1', '\n'};
  bytes.reserve(12 + metadata.size() +
                (result.sdr.pixels.size() + hdr.pixels.size()) * sizeof(float));
  append_u32_le(bytes, static_cast<std::uint32_t>(metadata.size()));
  bytes.insert(bytes.end(), metadata.begin(), metadata.end());
  append_float_image(bytes, result.sdr);
  append_float_image(bytes, hdr);
  return bytes;
}

std::vector<std::uint8_t> native_preview_packet(const GainMapResult& result,
    const DecodeInfo& decode, const InputDescription& input, bool hasCaptureMetadata) {
  return photo_preview_packet(renditions_from_gain_map(result),decode,input,hasCaptureMetadata);
}

std::vector<std::uint8_t> native_model_gain_packet(
    const NativeModelOutput& output, std::string_view input_domain) {
  const auto& gain = output.signed_log2_gain;
  gain.require_consistent("native model packet gain");
  if (gain.channels != 1 || gain.pixels.empty()) {
    throw std::invalid_argument(
        "native model packet gain must be non-empty single-channel data");
  }
  float min_stops = gain.pixels.front();
  float max_stops = gain.pixels.front();
  for (const float value : gain.pixels) {
    if (!std::isfinite(value) || value < -64.0F || value > 64.0F) {
      throw std::invalid_argument(
          "native model packet gain must be finite signed stops in [-64, 64]");
    }
    min_stops = std::min(min_stops, value);
    max_stops = std::max(max_stops, value);
  }
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.native-model-gain/v1")
      .member("width", gain.width)
      .member("height", gain.height)
      .member("channels", 1)
      .member("layout", "HW")
      .member("sampleType", "float32-le")
      .member("scale", "signed-log2-gain")
      .member("stride", kNativeModelStride)
      .member("gainMinStops", min_stops)
      .member("gainMaxStops", max_stops)
      .member("inputDomain", input_domain)
      .member("headroomStops", std::max(0.0F, max_stops))
      // Identity travels with the pixels. A caller that only knows what it asked
      // for cannot tell a fallback from an answer, and would label a
      // model-1 result as model 2's.
      .member("requestedModelId", output.requested_model_id)
      .member("effectiveModelId", output.effective_model_id)
      .member("modelVersion", output.model_version)
      .member("inferenceMode", output.inference_mode)
      .member("fallbackReason", output.fallback_reason)
      .member("baseOffsetNumerator", output.base_offset.numerator)
      .member("baseOffsetDenominator", output.base_offset.denominator)
      .member("alternateOffsetNumerator", output.alternate_offset.numerator)
      .member("alternateOffsetDenominator", output.alternate_offset.denominator);
  const std::string metadata = writer.end_object().take();

  std::vector<std::uint8_t> bytes{'H', 'Y', 'P', 'G', 'A', 'I', 'N', '1', '\n'};
  append_u32_le(bytes, static_cast<std::uint32_t>(metadata.size()));
  bytes.insert(bytes.end(), metadata.begin(), metadata.end());
  FloatImage packet_gain(gain.width, gain.height, 1);
  packet_gain.pixels = gain.pixels;
  append_float_image(bytes, packet_gain);
  return bytes;
}

void set_stdout_binary() {
#ifdef _WIN32
  // The model-gain packet is a byte protocol, not text. Prevent the CRT from
  // translating its header/newlines when the CLI is piped to the panel.
  _setmode(_fileno(stdout), _O_BINARY);
#endif
}

struct PreviewSource {
  std::string key;
  DecodedImage image;
  std::filesystem::path analysis_file;
  PhotographicAnalysis analysis;
  std::string preparation_key;
  GainMapPreparation preparation;
  std::string model_key;
  GainMapResult model_base;
  FloatImage model_input;
  NativeModelOutput prediction;
};

struct PreviewSession {
  std::vector<std::unique_ptr<PreviewSource>> sources;
  std::string raw_key;
  DecodedImage raw_master;
  PreviewSource& decode(const ConvertOptions& options) {
    const auto key = decode_cache_key(options.input,
        decode_cache_variant(options, options.raw), options.decode_cache_source_sha256);
    for (auto& source : sources) if (source->key == key) return *source;
    // One current photograph at its draft and final sizes, bounded in memory.
    if (sources.size() == 2) sources.erase(sources.begin());
    auto source = std::make_unique<PreviewSource>();
    source->key = key;
    if (options.raw.half_size && is_raw_extension(lower_extension(options.input))) {
      const auto cache_file = options.decode_cache_directory.empty()
          ? std::filesystem::path{} : decode_cache_path(options.decode_cache_directory, key);
      if (!cache_file.empty()) {
        source->analysis_file = cache_file.parent_path() /
            (cache_file.stem().string() + ".analysis.hdrcache");
      }
      const bool disk_hit = !cache_file.empty() && read_decode_cache(cache_file, source->image);
      if (!disk_hit) {
        // LibRaw produces the same half-size pixels for every preview edge.
        // Keep one such decode, then derive the two bounded render sizes below.
        auto master_options = options;
        master_options.preview_max_edge = 0;
        master_options.raw.preview_max_edge = 0;
        const auto master_key = decode_cache_key(options.input,
            decode_cache_variant(master_options, master_options.raw),
            options.decode_cache_source_sha256);
        if (raw_key != master_key) {
          raw_master = {};
          raw_key.clear();
          // This large intermediate belongs to this worker only. Persisting it
          // adds substantial disk I/O to the first frame and worker retirement.
          master_options.decode_cache_directory.clear();
          raw_master = decode_cached_image(options.input, master_options, master_options.raw);
          raw_key = master_key;
        }
        source->image = raw_master;
        source->image.linear_p3 = resample_to_max_edge(
            std::move(source->image.linear_p3), options.preview_max_edge);
        if (!cache_file.empty()) {
          static_cast<void>(write_decode_cache(cache_file, source->image,
              options.decode_cache_budget_bytes));
        }
      }
    } else {
      raw_master = {};
      raw_key.clear();
      source->image = decode_cached_image(options.input, options, options.raw, &source->analysis_file);
    }
    if (!source->image.raw_profile && source->image.domain == InputDomain::kSceneReferred) {
      source->analysis = cached_photographic_analysis(source->image.linear_p3,
          source->analysis_file, options.decode_cache_budget_bytes);
    }
    sources.push_back(std::move(source));
    return *sources.back();
  }
};

int preview_frame_command(int argc, char** argv, PreviewSession* session = nullptr,
                          std::vector<std::uint8_t>* packet = nullptr) {
  if (argc < 3) throw std::invalid_argument("preview-frame requires one input image");
  ConvertOptions options;
  options.decode_intent = DecodeIntent::Preview;
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
  validate_native_model_post_options(options.ai_post);
  if (!options.ai_model_path.empty() &&
      (!options.external_gain_path.empty() ||
       !options.external_gain_report.empty())) {
    throw std::invalid_argument(
        "--ai-model cannot be combined with an external gain grid");
  }
  options.raw.ignore_embedded_gain_map =
      !options.external_gain_path.empty() || !options.ai_model_path.empty();
  options.raw.default_gamut = options.default_gamut;
  // This subcommand is a bounded preview by definition -- the edge is forced
  // above if the caller left it out -- so the decoders may stop early rather
  // than materialise a 48 MP raster the next line is about to shrink. RAW
  // ignores this and keeps using --fast-preview's half_size.
  options.raw.preview_max_edge = options.preview_max_edge;
  std::filesystem::path analysis_cache;
  DecodedImage owned;
  PreviewSource* cached = session ? &session->decode(options) : nullptr;
  if (!cached) owned = decode_cached_image(options.input, options, options.raw, &analysis_cache);
  auto& decoded = cached ? cached->image : owned;
  const auto input = decoded.describe_input();
  const auto& capture = decoded.capture;
  const bool hasCaptureMetadata = capture.iso.has_value() || capture.exposure_time_seconds.has_value()
      || capture.aperture_f_number.has_value() || capture.exposure_bias_ev.has_value()
      || capture.focal_length_mm.has_value() || capture.focal_length_35mm.has_value();
  GainMapResult result;
  if (!options.ai_model_path.empty()) {
    const auto* analysis = cached && !decoded.raw_profile && input.domain == InputDomain::kSceneReferred
        ? &cached->analysis : nullptr;
    // The model id is part of the cache key, not just the request: without it a
    // cached model-1 base would be reused for model 2 and the preview would show
    // the previous model's picture under the new model's name.
    const auto model_key = selected_native_model_id(options) +
                           (options.clamp_srgb ? "/srgb" : "/p3");
    const auto request = native_model_request(options, decoded.metadata);
    if (is_sdr_encoding(options.encoding)) {
      result = render_native_model_base(decoded, options.clamp_srgb, analysis);
    } else if (cached) {
      if (cached->model_key != model_key) {
        cached->model_base = render_native_model_base(decoded, options.clamp_srgb, analysis);
        cached->model_input = make_native_model_input(cached->model_base.base_linear);
        cached->prediction = infer_native_model(request, cached->model_input);
        cached->model_key = model_key;
      }
      result = cached->model_base;
      apply_native_model_gain_map(result, cached->model_input, cached->prediction,
                                  options.gain.gain_strength, options.ai_post);
    } else {
      result = render_native_model_base(decoded, options.clamp_srgb);
      auto model_input = make_native_model_input(result.base_linear);
      auto prediction = infer_native_model(request, model_input);
      apply_native_model_gain_map(result, model_input, std::move(prediction),
                                  options.gain.gain_strength, options.ai_post);
    }
  } else if (!options.external_gain_path.empty()) {
    auto external = read_external_gain_map(
        options.external_gain_path, options.external_gain_report,
        options.allow_legacy_external_gain);
    const auto development = replay_external_development(
        external, options.input, decoded, options);
    result = make_external_gain_map(decoded.linear_p3, std::move(external),
                                    development, decoded.capture,
                                    decoded.describe_input());
  } else {
    if (cached) {
      json::Writer key;
      key.begin_object();
      for (const auto& setting : settings()) {
        if (setting.key == "gain_strength" || setting.key.starts_with("lut_")) continue;
        const auto value = setting.read(options);
        if (value.is_string()) key.member(setting.key, value.string());
        else if (value.is_bool()) key.member(setting.key, value.boolean());
        else key.member(setting.key, value.number());
      }
      const auto identity = key.end_object().take();
      if (cached->preparation_key != identity) {
        cached->preparation = {};
        cached->preparation_key = identity;
      }
    }
    auto photo=render_graded_photo(decoded.linear_p3,options.gain,decoded.capture,input,
        is_sdr_encoding(options.encoding) ? RenderTarget::Sdr : RenderTarget::Hdr,
        options.color_lut, nullptr,
        cached && !decoded.raw_profile && input.domain==InputDomain::kSceneReferred ? &cached->analysis : nullptr,
        cached ? &cached->preparation : nullptr);
    if(is_sdr_encoding(options.encoding)) fit_sdr_to_srgb(photo.sdr);
    if(options.encoding == OutputEncoding::Adaptive ||
        (options.encoding == OutputEncoding::UltraHdr && photo.hdr_is_source)) {
      result=gain_map_from_renditions(std::move(photo),
          options.encoding == OutputEncoding::UltraHdr ? GainMapWriterProfile::iso_generic
                                                      : GainMapWriterProfile::apple_strict);
    }
    else {
      validate_encoding_headroom(options.encoding,photo.stats.headroom_stops);
      auto bytes=photo_preview_packet(photo,decoded.decode,input,hasCaptureMetadata);
      if(packet) *packet=std::move(bytes);
      else write_binary_file_atomic(options.output_directory,bytes,true);
      return 0;
    }
  }
  if(!options.ai_model_path.empty() || !options.external_gain_path.empty()) {
    if(!options.color_lut.path.empty() || !is_gain_map_encoding(options.encoding)) {
      auto photo=render_graded_gain_map(result, options.color_lut, !is_sdr_encoding(options.encoding));
      if(is_sdr_encoding(options.encoding)) fit_sdr_to_srgb(photo.sdr);
      if(is_gain_map_encoding(options.encoding)) result.base_linear=std::move(photo.sdr);
      else {
        auto bytes=photo_preview_packet(photo,decoded.decode,input,hasCaptureMetadata);
        if(packet) *packet=std::move(bytes);
        else write_binary_file_atomic(options.output_directory,bytes,true);
        return 0;
      }
    }
  }
  validate_encoding_headroom(options.encoding, result.headroom_stops);
  if (packet) {
    *packet = !result.clamp_srgb && result.gain_map.channels == 1
        ? compact_preview_packet(result, decoded.decode, input,hasCaptureMetadata)
        : native_preview_packet(result, decoded.decode, input,hasCaptureMetadata);
  } else {
    write_binary_file_atomic(options.output_directory,
                             native_preview_packet(result, decoded.decode, input,hasCaptureMetadata), true);
  }
  return 0;
}

int preview_worker_command() {
  set_stdout_binary();
  PreviewSession session;
  std::cout << "{\"schema\":\"hyperdr.preview-worker/v1\"}\n" << std::flush;
  std::string line;
  while (std::getline(std::cin, line)) {
    try {
      const auto request = json::parse(line);
      std::vector<std::string> arguments{"HyperDR", "preview-frame"};
      for (const auto& value : request.array()) arguments.push_back(value.string());
      std::vector<char*> argv;
      for (auto& argument : arguments) argv.push_back(argument.data());
      std::vector<std::uint8_t> packet;
      preview_frame_command(static_cast<int>(argv.size()), argv.data(), &session, &packet);
      std::cout << "{\"size\":" << packet.size() << "}\n";
      std::cout.write(reinterpret_cast<const char*>(packet.data()), packet.size());
    } catch (const std::exception& error) {
      std::cout << "{\"size\":0,\"error\":\"" << json::escape(error.what()) << "\"}\n";
    }
    std::cout.flush();
  }
  return 0;
}

// Reads a developed HWC linear-P3 float32 tensor.  The bytes are exactly what
// `model-input` writes, so a conversion check can hand the model the same tensor
// PyTorch is about to be run on rather than a second decode of the same file.
FloatImage read_model_tensor(const std::filesystem::path& path,
                             std::uint32_t width, std::uint32_t height) {
  if (width == 0 || height == 0) {
    throw std::invalid_argument(
        "--input-tensor requires --tensor-width and --tensor-height");
  }
  if (width % kNativeModelStride != 0 || height % kNativeModelStride != 0) {
    throw std::invalid_argument(
        "input tensor dimensions must be stride-16 aligned");
  }
  const auto bytes = read_binary_file(path);
  FloatImage tensor(width, height, 3);
  const auto expected = tensor.pixels.size() * sizeof(float);
  if (bytes.size() != expected) {
    throw std::invalid_argument(
        "input tensor byte length does not match its declared dimensions");
  }
  // The runtime is little-endian only, which the model packet already declares;
  // reading a big-endian host's tensor would silently permute every sample.
  static_assert(std::endian::native == std::endian::little,
                "the model tensor file format is little-endian");
  std::memcpy(tensor.pixels.data(), bytes.data(), expected);
  for (const float value : tensor.pixels) {
    if (!std::isfinite(value) || value < 0.0F || value > 1.0F) {
      throw std::invalid_argument(
          "input tensor samples must be finite linear SDR in [0, 1]");
    }
  }
  return tensor;
}

// The capture settings that accompany a tensor.  A key that is absent, null or
// not finite is absent from the result, which is what makes this able to express
// the cases the fallback rule is tested with -- including a recorded exposure
// bias of exactly zero.
CaptureParameters read_capture_parameters(const std::filesystem::path& path) {
  CaptureParameters capture;
  const auto bytes = read_binary_file(path);
  const auto document = json::parse(
      std::string_view(reinterpret_cast<const char*>(bytes.data()), bytes.size()));
  if (!document.is_object()) {
    throw std::invalid_argument("--capture-json must contain a JSON object");
  }
  const auto value = [&](std::string_view key) -> std::optional<double> {
    const auto* found = document.find(key);
    if (found == nullptr || found->is_null()) return std::nullopt;
    if (!found->is_number()) {
      throw std::invalid_argument(std::string(key) +
                                  " must be a number or null");
    }
    const double number = found->number();
    if (!std::isfinite(number)) return std::nullopt;
    return number;
  };
  capture.iso = value("iso");
  capture.exposure_seconds = value("exposure_seconds");
  capture.f_number = value("f_number");
  capture.exposure_bias_ev = value("exposure_bias_ev");
  capture.focal_length_mm = value("focal_length_mm");
  capture.focal_length_35mm = value("focal_length_35mm");
  return capture;
}

int model_gain_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("model-gain requires one input image");
  ConvertOptions options;
  options.input = argv[2];
  parse_settings(argc, argv, 3, options);
  if (options.ai_model_path.empty()) {
    throw std::invalid_argument("model-gain requires --ai-model");
  }
  if (!options.external_gain_path.empty() ||
      !options.external_gain_report.empty()) {
    throw std::invalid_argument(
        "model-gain --ai-model cannot use an external gain grid");
  }
  if (options.model_input_tensor.empty() && !options.model_capture_path.empty()) {
    throw std::invalid_argument(
        "--capture-json describes an --input-tensor and needs one");
  }
  validate_native_model_post_options(options.ai_post);

  if (!options.model_input_tensor.empty()) {
    // No decode happens on this path, so there is no domain to declare and no
    // capture to read from a file; both are stated rather than guessed.
    const auto tensor = read_model_tensor(options.model_input_tensor,
                                         options.model_input_tensor_width,
                                         options.model_input_tensor_height);
    NativeModelRequest request;
    request.model_id = selected_native_model_id(options);
    if (!options.model_capture_path.empty()) {
      request.capture = read_capture_parameters(options.model_capture_path);
    }
    auto prediction = infer_native_model(request, tensor);
    set_stdout_binary();
    const auto packet = native_model_gain_packet(prediction, "undeclared");
    std::cout.write(reinterpret_cast<const char*>(packet.data()),
                    static_cast<std::streamsize>(packet.size()));
    if (!std::cout) throw std::runtime_error("failed writing native model packet");
    return 0;
  }

  if (options.preview_max_edge == 0) options.preview_max_edge = 2048;
  options.decode_intent = DecodeIntent::Preview;
  options.raw.preview_max_edge = options.preview_max_edge;
  options.raw.half_size = is_raw_extension(lower_extension(options.input));
  options.raw.ignore_embedded_gain_map = true;
  options.raw.default_gamut = options.default_gamut;
  validate_gain_map_options(options.gain);

  auto decoded = decode_cached_image(options.input, options, options.raw);
  const auto input = decoded.describe_input();
  auto result = render_native_model_base(decoded, options.clamp_srgb);
  auto model_input = make_native_model_input(result.base_linear);
  auto prediction = infer_native_model(native_model_request(options, decoded.metadata),
                                       model_input);
  set_stdout_binary();
  const auto packet =
      native_model_gain_packet(prediction, input_domain_name(input.domain));
  std::cout.write(reinterpret_cast<const char*>(packet.data()),
                  static_cast<std::streamsize>(packet.size()));
  if (!std::cout) throw std::runtime_error("failed writing native model packet");
  return 0;
}

int model_list_command(int argc, char** argv) {
  // `--json` is accepted for symmetry with `inspect`; the table is always JSON so
  // the panel has one parse path rather than two. The adapter was registered
  // during startup, so `available` already reflects whether every asset loaded.
  for (int i = 2; i < argc; ++i) {
    if (std::string_view(argv[i]) != "--json") {
      throw std::invalid_argument("unknown model-list option: " +
                                  std::string(argv[i]));
    }
  }
  std::cout << native_model_list_json() << "\n";
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
                               const ConvertOptions& options,
                               const FloatImage& tensor) {
  const auto& d = decoded.decode;
  json::Writer writer(json::Writer::Style::kIndented);
  writer.begin_object()
      .member("schema", "hyperdr.model-input/v2")
      .member("pipeline_revision", kRenderPipelineRevision)
      .member("preprocessing_fingerprint", model_preprocessing_fingerprint(options))
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
      .member("raw_profile_sha256", decoded.raw_profile ? decoded.raw_profile->profile->sha256 : "")
      .member("raw_lens_profile_sha256", decoded.raw_lens_profile_path.empty() ? std::string{} : sha256_file_hex(decoded.raw_lens_profile_path))
      .member("raw_half_size", raw.half_size)
      .member("input_domain", input_domain_name(decoded.describe_input().domain))
      .member("default_crop_present", d.default_crop_present)
      .member("requested_crop_applied", d.target_dimensions_applied)
      .begin_object("development_recipe")
      .member("id", decoded.raw_profile ? "raw-dcp-v1" : native_model_development_kind(
                        decoded.describe_input().domain))
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
      .member("resize_convention", kResampleConvention)
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
    } else if (arg == "--raw-bad-pixels") {
      options.raw.bad_pixel_map = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-dark-frame") {
      options.raw.dark_frame = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-linearization-lut") {
      options.raw.linearization_lut = next_value(i, argc, argv, arg);
    } else if (arg == "--raw-lens-shading") {
      options.raw.lens_shading_map = next_value(i, argc, argv, arg);
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
  options.raw.default_gamut = options.default_gamut;
  auto decoded = decode_image(input, options.raw);
  // Keep cache generation identical to the deployed input/base preparation.
  GainMapOptions development_options{};
  development_options.exposure_bias_ev = 0.0F;
  development_options.clamp_srgb = options.clamp_srgb;
  development_options.gain_strength = 1.0F;
  development_options.look.contrast = 1.0F;
  development_options.look.vibrance = 0.0F;
  development_options.look.pop = 0.0F;
  if (decoded.describe_input().domain == InputDomain::kDisplayReferredSdr) {
    development_options.gain_strength = 0.0F;
  }
  auto developed = render_native_model_base(decoded, options.clamp_srgb);
  const auto [width, height] = model_tensor_size(
      developed.base_linear.width, developed.base_linear.height, long_side);
  auto tensor = resample_to(developed.base_linear, width, height);
  write_binary_file_atomic(output, float32_le_bytes(tensor), true);
  write_text_file_atomic(report,
                         model_input_report(input, output, decoded, developed,
                                            development_options, options.raw, options, tensor),
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
  if (command == "raw-metadata") {
    if (argc != 3) throw std::invalid_argument("raw-metadata requires one RAW path");
    const auto metadata = probe_raw_lens_metadata(path_from_utf8(argv[2]));
    json::Writer writer;
    writer.begin_object().member("make", metadata.make).member("model", metadata.model)
        .member("lens", metadata.lens).member("focalLength", metadata.focal_length)
        .member("aperture", metadata.aperture).end_object();
    std::cout << writer.take() << '\n';
    return 0;
  }
  if (command == "inspect") return inspect_command(argc, argv);
  if (command == "verify") return verify_command(argc, argv);
  if (command == "thumbnail") return thumbnail_command(argc, argv);
  if (command == "preview-frame") return preview_frame_command(argc, argv);
  if (command == "preview-worker") return preview_worker_command();
  if (command == "model-gain") return model_gain_command(argc, argv);
  if (command == "model-input") return model_input_command(argc, argv);
  if (command == "model-list") return model_list_command(argc, argv);
  throw std::invalid_argument("unknown command: " + std::string(command));
}

}  // namespace hyperdr
