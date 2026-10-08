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
#include "hyperdr/app/source_defaults.hpp"
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
#include <optional>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

#include "cli_commands.hpp"

namespace hyperdr {
using namespace app::detail;
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
         "  HyperDR verify <file.heic|file.jpg|file.tiff> [--reconstruct <preview.tiff>]\n"
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

FloatImage crop_preview_plane(const FloatImage& image, const PreviewRegion& region) {
  if (image.pixels.empty()) return {};
  FloatImage cropped(*region.width, *region.height, image.channels);
  const auto row_samples = static_cast<std::size_t>(*region.width) * image.channels;
  for (std::uint32_t y = 0; y < *region.height; ++y) {
    const auto source = (static_cast<std::size_t>(*region.top + y) * image.width +
                         *region.left) * image.channels;
    std::copy_n(image.pixels.data() + source, row_samples,
                cropped.pixels.data() + static_cast<std::size_t>(y) * row_samples);
  }
  return cropped;
}

PhotoRenditions crop_preview_photo(PhotoRenditions photo,
                                   const PreviewRegion& region) {
  photo.sdr = crop_preview_plane(photo.sdr, region);
  photo.hdr = crop_preview_plane(photo.hdr, region);
  return photo;
}

std::vector<std::uint8_t> photo_preview_packet(const PhotoRenditions& result,
                                                const DecodeInfo& decode,
                                                const InputDescription& input, bool hasCaptureMetadata,
                                                const SourceColorInfo& source_color,
                                                const PreviewRegion* region = nullptr,
                                                std::uint32_t full_width = 0,
                                                std::uint32_t full_height = 0) {
  // Wire format v1: magic, JSON byte length, UTF-8 JSON, then two tightly
  // packed little-endian HWC RGB float32 planes (SDR base, reconstructed HDR).
  // JSON makes status/geometry extensible while the pixel payload stays
  // directly uploadable to GPU textures without an 8-bit colour conversion.
  const auto& hdr = result.hdr.pixels.empty() ? result.sdr : result.hdr;
  const auto defaults = source_defaults(input.domain);
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
      .begin_object("sourceColor")
      .member("name", source_color.name)
      .member("primaries", source_color.primaries)
      .member("transfer", source_color.transfer)
      .member("source", source_color.source)
      .end_object()
      .member("hasCaptureMetadata", hasCaptureMetadata)
      .member("inputHeadroomStops", std::log2(input.headroom))
      .member("status", decode.degraded ? "degraded" : "ok")
      .begin_object("unadjusted")
      .member("brightness", defaults.brightness_ev)
      .member("hdrStrength", defaults.hdr_strength)
      .member("hdrRange", defaults.hdr_range_stops)
      .member("areaCoverage", defaults.area_coverage)
      .member("lutStrength", defaults.lut_strength)
      .end_object();
  if (region) {
    writer.member("detail", true)
        .member("fullWidth", full_width)
        .member("fullHeight", full_height)
        .member("regionX", *region->left)
        .member("regionY", *region->top);
  }
  if (input.content_peak_nits) writer.member("inputContentPeakNits", *input.content_peak_nits);
  writer.begin_array("degradationReasons");
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
    const DecodeInfo& decode, const InputDescription& input, bool hasCaptureMetadata,
    const SourceColorInfo& source_color) {
  return photo_preview_packet(renditions_from_gain_map(result),decode,input,
                              hasCaptureMetadata, source_color);
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
    for (std::size_t i = 0; i < sources.size(); ++i) {
      if (sources[i]->key != key) continue;
      // A detail pan should find the full demosaic that the last pan used.
      auto hit = std::move(sources[i]);
      sources.erase(sources.begin() + static_cast<std::ptrdiff_t>(i));
      sources.push_back(std::move(hit));
      return *sources.back();
    }
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
        source->image.transform_planes([&](FloatImage plane) {
          return resample_to_max_edge(std::move(plane), options.preview_max_edge);
        });
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
    constexpr std::size_t kDecodedBudget = 768ULL * 1024 * 1024;
    const auto decoded_bytes = [](const PreviewSource& item) {
      std::size_t bytes = item.image.linear_p3.pixels.size() * sizeof(float);
      if (item.image.authored_sdr) bytes += item.image.authored_sdr->pixels.size() * sizeof(float);
      return bytes;
    };
    std::size_t retained = 0;
    for (const auto& item : sources) retained += decoded_bytes(*item);
    while (sources.size() > 1 && (sources.size() > 3 || retained > kDecodedBudget)) {
      retained -= decoded_bytes(*sources.front());
      sources.erase(sources.begin());
    }
    return *sources.back();
  }
};

int preview_frame_command(int argc, char** argv, PreviewSession* session = nullptr,
                          std::vector<std::uint8_t>* packet = nullptr) {
  if (argc < 3) throw std::invalid_argument("preview-frame requires one input image");
  ConvertOptions options;
  options.decode_intent = DecodeIntent::Preview;
  options.input = path_from_utf8(argv[2]);
  PreviewRegion region;
  parse_settings(argc, argv, 3, options, nullptr, &region);
  apply_output_color_options(options);
  if (options.output_directory.empty()) {
    throw std::invalid_argument("preview-frame --output is required");
  }
  const bool detail = region.requested();
  if (detail) {
    // A detail crop must start from the full decode. Neither a decoder resize
    // nor LibRaw half-size output can recover sensor detail afterward.
    options.preview_max_edge = 0;
    options.raw.preview_max_edge = 0;
    options.raw.half_size = false;
  } else if (options.preview_max_edge == 0) {
    options.preview_max_edge = 2048;
  }
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
  options.raw.ignore_embedded_gain_map = false;
  options.raw.default_gamut = options.default_gamut;
  // Ordinary previews may decode at a bounded edge. Detail requests leave
  // this at zero so the decoder preserves native pixels before cropping.
  options.raw.preview_max_edge = options.preview_max_edge;
  std::filesystem::path analysis_cache;
  DecodedImage owned;
  PreviewSource* cached = session ? &session->decode(options) : nullptr;
  if (!cached) owned = decode_cached_image(options.input, options, options.raw, &analysis_cache);
  auto& decoded = cached ? cached->image : owned;
  const auto full_width = decoded.linear_p3.width;
  const auto full_height = decoded.linear_p3.height;
  if (detail) region.resolve(full_width, full_height);
  const auto input = decoded.describe_input();
  if ((input.domain == InputDomain::kDisplayReferredHdr ||
       input.domain == InputDomain::kDualRendition) &&
      (!options.ai_model_path.empty() || !options.external_gain_path.empty())) {
    throw std::invalid_argument(
        "--ai-model and --external-gain require SDR or RAW input; HDR and dual-rendition photos already contain authored HDR");
  }
  const auto& capture = decoded.capture;
  const bool hasCaptureMetadata = capture.iso.has_value() || capture.exposure_time_seconds.has_value()
      || capture.aperture_f_number.has_value() || capture.exposure_bias_ev.has_value()
      || capture.focal_length_mm.has_value() || capture.focal_length_35mm.has_value();
  const auto packet_from_photo = [&](PhotoRenditions photo) {
    if (detail) photo = crop_preview_photo(std::move(photo), region);
    return photo_preview_packet(photo, decoded.decode, input, hasCaptureMetadata,
        decoded.source_color,
        detail ? &region : nullptr, full_width, full_height);
  };
  const auto release_detail_render_cache = [&] {
    if (!detail || !cached) return;
    // Panning needs the full decoder result, not several full-resolution
    // rendered copies. Rebuild adjustment-specific intermediates on demand.
    cached->preparation = {};
    cached->model_base = {};
    cached->model_input = {};
    cached->prediction = {};
    cached->model_key.clear();
  };
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
    if (is_sdr_encoding(options.encoding) &&
        resolved_sdr_gamut(options) == ColorGamut::kSrgb) fit_sdr_to_srgb(photo.sdr);
    if(options.encoding == OutputEncoding::Adaptive ||
        (options.encoding == OutputEncoding::UltraHdr && photo.hdr_is_source)) {
      result=gain_map_from_renditions(std::move(photo),
          options.encoding == OutputEncoding::UltraHdr ? GainMapWriterProfile::iso_generic
                                                      : GainMapWriterProfile::apple_strict);
    }
    else {
      validate_encoding_headroom(options.encoding,photo.stats.headroom_stops);
      auto bytes=packet_from_photo(std::move(photo));
      if(packet) *packet=std::move(bytes);
      else write_binary_file_atomic(options.output_directory,bytes,true);
      release_detail_render_cache();
      return 0;
    }
  }
  if(!options.ai_model_path.empty() || !options.external_gain_path.empty()) {
    if(!options.color_lut.path.empty() || !is_gain_map_encoding(options.encoding)) {
      auto photo=render_graded_gain_map(result, options.color_lut, !is_sdr_encoding(options.encoding));
      if (is_sdr_encoding(options.encoding) &&
          resolved_sdr_gamut(options) == ColorGamut::kSrgb) fit_sdr_to_srgb(photo.sdr);
      if(is_gain_map_encoding(options.encoding)) result.base_linear=std::move(photo.sdr);
      else {
        auto bytes=packet_from_photo(std::move(photo));
        if(packet) *packet=std::move(bytes);
        else write_binary_file_atomic(options.output_directory,bytes,true);
        release_detail_render_cache();
        return 0;
      }
    }
  }
  validate_encoding_headroom(options.encoding, result.headroom_stops);
  if (detail) {
    auto bytes = packet_from_photo(renditions_from_gain_map(std::move(result)));
    if (packet) *packet = std::move(bytes);
    else write_binary_file_atomic(options.output_directory, bytes, true);
    release_detail_render_cache();
    return 0;
  }
  if (packet) {
    *packet = !result.clamp_srgb && result.gain_map.channels == 1
        ? compact_preview_packet(result, decoded.decode, input, hasCaptureMetadata,
                                 decoded.source_color)
        : native_preview_packet(result, decoded.decode, input, hasCaptureMetadata,
                                decoded.source_color);
  } else {
    write_binary_file_atomic(options.output_directory,
                             native_preview_packet(result, decoded.decode, input,
                                                   hasCaptureMetadata, decoded.source_color), true);
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
  if (command == "raw-metadata") return raw_metadata_command(argc, argv);
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
