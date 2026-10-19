#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/analysis_cache.hpp"

#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/discovery.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/report.hpp"
#include "hyperdr/app/resume_state.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/configuration_error.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/native_model.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <fstream>
#include <sstream>
#include "hyperdr/foundation/cancel.hpp"
#include <new>
#include <optional>
#include <set>
#include <utility>

namespace hyperdr {
namespace {

using Clock = std::chrono::steady_clock;

double milliseconds(Clock::time_point begin, Clock::time_point end) {
  return std::chrono::duration<double, std::milli>(end - begin).count();
}

// One file's work is split in two so a batch can overlap the stages. A staged
// item whose decode failed, or which was skipped, already carries its final
// result.
struct Staged {
  FileResult result;
  DecodedImage image;
  InputStamp input_stamp{};
  bool decoded{false};
  double decode_ms{};
  std::filesystem::path analysis_cache;
};

bool raster_preview_matches_full(const DecodeInfo& decoded) {
  if (!decoded.target_dimensions_applied || !decoded.decoded_width || !decoded.decoded_height)
    return false;
  // Raster decoders reduce both axes by one integer factor and round up.
  // The reduced raster still covers the entire source crop.
  for (std::uint64_t factor = 1; factor <= 64; ++factor) {
    if (decoded.decoded_width == (decoded.target_width + factor - 1) / factor &&
        decoded.decoded_height == (decoded.target_height + factor - 1) / factor)
      return true;
  }
  return false;
}

}  // namespace

GainMapResult render_decoded_image(const DecodedImage& image,
                                   const GainMapOptions& options,
                                   const std::filesystem::path& analysis_cache,
                                   std::uint64_t cache_budget_bytes) {
  if (!analysis_cache.empty() && image.describe_input().domain == InputDomain::kSceneReferred) {
    const auto analysis = cached_photographic_analysis(image.linear_p3, analysis_cache, cache_budget_bytes);
    return make_gain_map(image.linear_p3, options, image.capture, image.describe_input(), &analysis);
  }
  return make_gain_map(image.linear_p3, options, image.capture,
                       image.describe_input());
}

const char* native_model_development_kind(InputDomain domain) noexcept {
  switch (domain) {
    case InputDomain::kDisplayReferredSdr:
      return "display-p3-passthrough";
    case InputDomain::kSceneReferred:
      return "raw-neutral-v2";
    case InputDomain::kDisplayReferredHdr:
      return "display-hdr-split";
    case InputDomain::kDualRendition:
      return "none";
    case InputDomain::kUnknown:
      return "none";
  }
  return "none";
}

GainMapResult render_native_model_base(const DecodedImage& image,
                                       bool clamp_srgb,
                                       const PhotographicAnalysis* analysis) {
  GainMapOptions development{};
  development.clamp_srgb = clamp_srgb;
  development.exposure_bias_ev = 0.0F;
  development.gain_strength = 1.0F;
  development.look.contrast = 1.0F;
  development.look.vibrance = 0.0F;
  development.look.pop = 0.0F;

  // make_display_referred_sdr_result only invokes photographic expansion when
  // mathematical gain is requested. Zero gain therefore selects its exact
  // linear Display-P3 passthrough result; the inferred gain replaces the zero
  // grid immediately afterwards.
  if (image.describe_input().domain == InputDomain::kDisplayReferredSdr) {
    development.gain_strength = 0.0F;
  }
  return make_gain_map(image.linear_p3, development, image.capture,
      image.describe_input(), analysis);
}

GainMapOptions replay_external_development(
    const ExternalGainMap& external, const std::filesystem::path& input,
    const DecodedImage& image, const ConvertOptions& options) {
  if (!external.binding) return options.gain;
  const auto& binding = *external.binding;
  const auto& decoded = image.decode;
  const auto reject = [](std::string_view reason) {
    throw std::invalid_argument("external gain model binding mismatch: " +
                                std::string(reason));
  };
  if(binding.recipe.id=="raw-neutral-v1" || binding.recipe.id=="raw-dcp-v1" || binding.recipe.id=="photographic-v1")
    reject("配方不匹配，请用新版本重新生成");
  if (sha256_file_hex(input) != binding.source_sha256) {
    reject("source sha256");
  }
  auto preprocessing_options = options;
  preprocessing_options.input = input;
  if (binding.preprocessing_fingerprint != model_preprocessing_fingerprint(preprocessing_options)) {
    reject("preprocessing changed; regenerate the model input and gain");
  }
  if (binding.orientation != image.metadata.orientation) {
    reject("orientation");
  }
  if (binding.sensor_width != decoded.sensor_width ||
      binding.sensor_height != decoded.sensor_height) {
    reject("sensor raster");
  }
  if (binding.requested_crop_width != decoded.target_width ||
      binding.requested_crop_height != decoded.target_height ||
      binding.requested_crop_left != decoded.requested_crop_left ||
      binding.requested_crop_top != decoded.requested_crop_top) {
    reject("requested crop");
  }
  if (binding.delivered_crop_left != decoded.delivered_crop_left ||
      binding.delivered_crop_top != decoded.delivered_crop_top) {
    reject("delivered crop origin");
  }
  const bool same_delivered_size =
      binding.delivered_crop_width == decoded.decoded_width &&
      binding.delivered_crop_height == decoded.decoded_height;
  const bool raster_preview = options.decode_intent == DecodeIntent::Preview &&
      (image.domain == InputDomain::kDisplayReferredSdr ||
       image.domain == InputDomain::kDisplayReferredHdr) &&
      binding.delivered_crop_width == decoded.target_width &&
      binding.delivered_crop_height == decoded.target_height &&
      raster_preview_matches_full(decoded);
  const bool delivered_matches = decoded.raw
      ? same_delivered_size && binding.raw_decoder_version==decoded.raw->decoder_version && binding.raw_scale==decoded.raw->scale
      : raster_preview || same_delivered_size;
  if (!delivered_matches) reject("delivered crop");

  const auto expected_recipe =
      native_model_development_kind(image.describe_input().domain);
  if(binding.recipe.id != expected_recipe) reject("配方不匹配，请用新版本重新生成");
  GainMapOptions replay = options.gain;
  replay.auto_exposure = false;
  replay.exposure_ev = binding.recipe.exposure_ev;
  replay.exposure_bias_ev = 0.0F;
  replay.auto_headroom = false;
  replay.headroom_stops = binding.recipe.headroom_stops;
  // The recipe's headroom belongs to the model's SDR development and may be
  // higher than the current panel/output ceiling. Keep that recipe valid for
  // replay, then let the external renderer attenuate the gain map to the
  // selected format limit.
  replay.look.headroom_max_stops = std::max(
      replay.look.headroom_max_stops, binding.recipe.headroom_stops);
  replay.output_headroom_limit_stops = options.gain.auto_headroom
      ? options.gain.look.headroom_max_stops
      : options.gain.headroom_stops;
  // make_external_gain_map saves this value for the external grid, then uses
  // unity for the mathematical pass that reproduces the SDR base.
  replay.gain_strength = options.gain.gain_strength;
  replay.look.contrast = binding.recipe.contrast;
  replay.look.vibrance = binding.recipe.vibrance;
  replay.look.pop = binding.recipe.pop;
  replay.look.toe_end = binding.recipe.toe_end;
  replay.look.toe_output_ratio = binding.recipe.toe_output_ratio;
  replay.look.shoulder_start = binding.recipe.shoulder_start;
  replay.look.positive_exposure_limit_ev =
      binding.recipe.positive_exposure_limit_ev;
  replay.look.diffuse_gain_floor = binding.recipe.diffuse_gain_floor;
  validate_gain_map_options(replay);
  return replay;
}

namespace {

Staged decode_stage(const std::filesystem::path& path,
                    const ConvertOptions& options,
                    const std::string& fingerprint) {
  Staged staged;
  staged.result.input = path;
  try {
    staged.result.output = output_path_for(path, options);
    if (options.skip_existing &&
        output_is_current(staged.result.output, path, options, fingerprint)) {
      staged.result.success = true;
      staged.result.skipped = true;
      staged.result.message = "skipped: output matches the current settings";
      return staged;
    }
    const auto start = Clock::now();
    staged.input_stamp = input_stamp(path);
    auto raw = options.raw;
    raw.default_gamut = options.default_gamut;
    // Keep the authored base and gain map so the decoded domain can enforce
    // the model/external-gain restriction before any rendition is replaced.
    raw.ignore_embedded_gain_map = false;
    // Only an explicitly declared preview lets the decoders reduce on their
    // own. An export keeps decoding at full size and reaches --preview-max-edge
    // through the linear-light resampler alone, so its bytes do not change.
    if (options.decode_intent == DecodeIntent::Preview) {
      raw.preview_max_edge = options.preview_max_edge;
    } else {
      raw.preview_max_edge = 0;
    }

    staged.image = decode_cached_image(path, options, raw, &staged.analysis_cache);
    staged.decode_ms = milliseconds(start, Clock::now());
    staged.decoded = true;
  } catch (const Cancelled&) {
    throw;
  } catch (const RawUnsupported& e) {
    staged.decoded=false;staged.result.message=e.what();staged.result.detail=e.what();
    staged.result.error_code="raw_unsupported";staged.result.error_detail_json=e.detail_json();
  } catch (const std::bad_alloc&) {
    staged.decoded = false;
    staged.result.message = options.decode_intent == DecodeIntent::Export
                                ? "insufficient memory for full-resolution decode"
                                : "insufficient memory for preview decode";
  } catch (const std::exception& e) {
    staged.decoded = false;
    staged.result.message = e.what();
  }
  return staged;
}

// Freeze external frame inputs before fingerprinting, callbacks or photo I/O.
void prepare_frame_snapshot(ConvertOptions& options) {
  if (options.frame_snapshot || (!options.frame && options.frame_spec_path.empty())) return;
  auto snapshot = std::make_shared<FrameSnapshot>();
  configuration_resource([&] {
    if (!options.frame_spec_path.empty()) {
      snapshot->specification_bytes = read_binary_file(options.frame_spec_path);
      const auto& bytes = snapshot->specification_bytes;
      snapshot->spec = parse_frame_spec(json::parse(std::string_view(
          reinterpret_cast<const char*>(bytes.data()), bytes.size())), options.frame_spec_path.parent_path());
    } else {
      snapshot->spec = *options.frame;
    }
    validate_frame_resources(snapshot->spec);
    if (!snapshot->spec.overlay.empty()) {
      snapshot->overlay_bytes = read_binary_file(snapshot->spec.overlay);
      snapshot->overlay_sha256 = sha256_hex(snapshot->overlay_bytes);
      snapshot->overlay = decode_frame_overlay(snapshot->overlay_bytes);
    }
  });
  options.frame = snapshot->spec;
  options.frame_spec_path.clear();
  options.frame_snapshot = std::move(snapshot);
}

// Places the presentation frame around both renditions. Every frame pixel is
// identical in SDR and HDR, so whichever writer packages the pair stores zero
// gain there and the frame shows at its SDR value on every HDR display.
FrameLayout frame_photo(PhotoRenditions& photo, const FrameSnapshot& snapshot) {
  const auto& spec = snapshot.spec;
  const auto layout = layout_frame(spec, photo.sdr.width, photo.sdr.height);
  const FrameOverlay* ink = spec.overlay.empty() ? nullptr : &snapshot.overlay;
  photo.sdr = frame_image(photo.sdr, spec, layout, ink);
  if (!photo.hdr.pixels.empty()) photo.hdr = frame_image(photo.hdr, spec, layout, ink);
  // A frame pixel is the same in both renditions, which is exactly what the
  // below-knee check asks of a pixel; the report then measures the frame too.
  photo.below_knee = frame_mask(photo.below_knee, layout, 1);
  return layout;
}

// A model or external gain grid describes the photograph alone and cannot be
// padded: a zero-gain code may not exist in its range, and its offsets make
// "no gain" depend on the pixel. Its reconstructed pair is an authored dual
// rendition, so it is packaged as one, keeping signed gain and those offsets.
void adopt_as_authored(PhotoRenditions& photo, const GainMapMetadata& metadata) {
  const auto channels = gain_map_channel_count(metadata);
  photo.dual_rendition = true;
  photo.authored_gain_channels = static_cast<std::uint32_t>(channels);
  photo.fixed_gain_channels = true;
  photo.authored_gain_map.channels = static_cast<std::uint32_t>(channels);
  for (unsigned c = 0; c < 3; ++c) {
    const auto channel = gain_map_channel(metadata, channels == 1 ? 0 : c);
    photo.authored_gain_map.base_offset[c] = rational_value(channel.base_offset);
    photo.authored_gain_map.alternate_offset[c] = rational_value(channel.alternate_offset);
  }
}

std::vector<std::uint8_t> encode_for(const PhotoRenditions& photo, const GainMapResult& images,
                                     const PhotoMetadata& metadata,
                                     const ConvertOptions& options) {
  switch (options.encoding) {
    case HdrEncoding::SdrJpeg:
      return encode_sdr_jpeg(photo.sdr, metadata, options.quality, resolved_sdr_gamut(options));
    case HdrEncoding::SdrTiff:
      return encode_sdr_tiff(photo.sdr, metadata, resolved_sdr_gamut(options));
    case HdrEncoding::Adaptive:
      return encode_adaptive_heic(images, metadata, options.quality, options.depth,
                                  options.hevc_preset);
    case HdrEncoding::IsoGainMapJpeg:
      return encode_gain_map_jpeg(images, metadata, options.quality);
    case HdrEncoding::AvifPq:
    case HdrEncoding::AvifHlg:
      return encode_avif(photo, metadata, options.quality, options.encoding);
    case HdrEncoding::Pq:
    case HdrEncoding::Hlg:
      break;
  }
  return encode_hdr_heic(photo, metadata, options.quality, options.encoding,
                         options.hevc_preset);
}

void verify_encoded(const std::vector<std::uint8_t>& bytes,
                    const ConvertOptions& options) {
  if (options.encoding == HdrEncoding::SdrTiff) verify_sdr_tiff(bytes);
  else if (options.encoding == HdrEncoding::SdrJpeg) verify_sdr_jpeg(bytes);
  else if (options.encoding == HdrEncoding::IsoGainMapJpeg) verify_gain_map_jpeg(bytes);
  else if (is_avif_encoding(options.encoding)) verify_avif_decodable(bytes);
  else verify_heic_decodable(bytes, options.encoding);
}

void finish_stage(Staged& staged, const ConvertOptions& options,
                  const std::string& fingerprint, ProgressSink* sink) {
  if (!staged.decoded) return;
  auto& result = staged.result;
  try {
    const auto decoded = Clock::now();
    if (options.decode_intent == DecodeIntent::Export &&
        (options.encoding == OutputEncoding::IsoGainMapJpeg || options.encoding == OutputEncoding::SdrJpeg)) {
      const auto& dimensions = staged.image.decode;
      if (dimensions.target_width > 65500 || dimensions.target_height > 65500)
        throw ExportDimensionLimit(dimensions.target_width, dimensions.target_height);
    }
    require_decode_resolution(options, staged.image.decode);
    const auto domain = staged.image.describe_input().domain;
    if ((domain == InputDomain::kDisplayReferredHdr ||
         domain == InputDomain::kDualRendition) &&
        (!options.ai_model_path.empty() || !options.external_gain_path.empty())) {
      throw std::invalid_argument(
          "--ai-model and --external-gain require SDR or RAW input; HDR and dual-rendition photos already contain authored HDR");
    }
    std::optional<ExternalGainMap> external;
    if (!options.external_gain_path.empty()) {
      // Parse per file so an invalid grid stays a per-file failure, as before.
      external = options.external_gain_snapshot
          ? parse_external_gain_map(options.external_gain_snapshot->gain_bytes,
                                    options.external_gain_snapshot->report_bytes,
                                    options.allow_legacy_external_gain)
          : read_external_gain_map(options.external_gain_path,
                                         options.external_gain_report,
                                         options.allow_legacy_external_gain);
    }
    GainMapResult gain;
    PhotoRenditions photo;
    const auto target = is_sdr_encoding(options.encoding) ? RenderTarget::Sdr : RenderTarget::Hdr;
    // Identity of the model that actually produced this file's gain. Assigned
    // here rather than derived later from the options, because the options only
    // say what was asked for: model 2 answering with model 1's prediction is a
    // successful run with a different model behind it, and a report that echoed
    // the request would call it model 2.
    if (uses_native_model(options)) {
      const auto requested = selected_native_model_id(options);
      result.model_requested_id = requested;
      result.model_id = requested;
      result.model_version =
          std::string(native_model_descriptor(requested).version);
      result.model_inference_mode = std::string(kInferenceModeNotRun);
    }
    if (!options.ai_model_path.empty()) {
      // The model consumes and retains one shared SDR base: decoded linear P3
      // for finished SDR, or the fixed neutral development for scene RAW.
      gain = render_native_model_base(staged.image, options.clamp_srgb);
      if (target == RenderTarget::Hdr) {
        auto model_input = make_native_model_input(gain.base_linear);
        auto prediction = infer_native_model(
            native_model_request(options, staged.image.metadata), model_input);
        result.model_id = prediction.effective_model_id;
        result.model_version = prediction.model_version;
        result.model_inference_mode = prediction.inference_mode;
        result.model_fallback_reason = prediction.fallback_reason;
        apply_native_model_gain_map(gain, model_input, std::move(prediction),
                                  options.gain.gain_strength, options.ai_post);
      }
    } else if (external) {
      const auto development = replay_external_development(
          *external, staged.result.input, staged.image, options);
      gain = make_external_gain_map(staged.image.linear_p3, std::move(*external),
          development, staged.image.capture, staged.image.describe_input());
    }
    if (options.ai_model_path.empty() && !external) {
      photo = render_graded_photo(staged.image.linear_p3, options.gain, staged.image.capture,
          staged.image.describe_input(), target, options.color_lut);
    } else {
      photo = render_graded_gain_map(gain, options.color_lut, target == RenderTarget::Hdr);
    }
    const bool predicted_gain = !options.ai_model_path.empty() || external.has_value();
    if (options.frame) {
      if (predicted_gain && target == RenderTarget::Hdr) adopt_as_authored(photo, gain.metadata);
      result.frame = frame_photo(photo, *options.frame_snapshot);
    }
    if (is_sdr_encoding(options.encoding) && resolved_sdr_gamut(options) == ColorGamut::kSrgb)
      fit_sdr_to_srgb(photo.sdr);
    const bool explicit_gain = is_gain_map_encoding(options.encoding);
    if (predicted_gain && options.encoding == OutputEncoding::IsoGainMapJpeg)
      adopt_as_authored(photo, gain.metadata);
    if (explicit_gain) {
      if (!predicted_gain || result.frame || options.encoding == OutputEncoding::IsoGainMapJpeg) {
        gain = gain_map_from_renditions(std::move(photo),
            options.encoding == OutputEncoding::IsoGainMapJpeg ? GainMapWriterProfile::iso_generic
                                                        : GainMapWriterProfile::apple_strict);
      }
      else gain.base_linear = std::move(photo.sdr);
    }
    const auto& rendered_stats = explicit_gain ? gain.stats : photo.stats;
    const auto& rendered_base = explicit_gain ? gain.base_linear : photo.sdr;
    // Validate the peak the renderer actually produced. External model
    // metadata arrives after the initial option validation and can otherwise
    // bypass HLG's 1000-nit ceiling.
    validate_encoding_headroom(options.encoding, rendered_stats.headroom_stops);
    result.sensor_width = staged.image.decode.sensor_width;
    result.source_color = staged.image.source_color;
    result.raw_processing = staged.image.decode.raw;
    result.sensor_height = staged.image.decode.sensor_height;
    result.target_width = staged.image.decode.target_width;
    result.target_height = staged.image.decode.target_height;
    result.decoded_width = staged.image.decode.decoded_width;
    result.decoded_height = staged.image.decode.decoded_height;
    result.requested_crop_width = staged.image.decode.target_width;
    result.requested_crop_height = staged.image.decode.target_height;
    result.delivered_crop_width = staged.image.decode.decoded_width;
    result.delivered_crop_height = staged.image.decode.decoded_height;
    result.target_dimensions_applied =
        staged.image.decode.target_dimensions_applied;
    result.default_crop_present = staged.image.decode.default_crop_present;
    result.decode_degraded = staged.image.decode.degraded;
    result.decode_degradation_reasons =
        staged.image.decode.degradation_reasons;
    const auto described = staged.image.describe_input();
    result.input_domain = described.domain;
    result.input_headroom = described.headroom;
    result.input_content_peak_nits = described.content_peak_nits;
    result.model_development = options.ai_model_path.empty()
                                   ? "none"
                                   : native_model_development_kind(
                                         described.domain);
    result.width = rendered_base.width;
    result.height = rendered_base.height;
    result.exposure_ev = rendered_stats.exposure_ev;
    result.headroom_stops = explicit_gain ? gain.headroom_stops : photo.stats.headroom_stops;
    result.stats = rendered_stats;
    result.gain_min = explicit_gain ? rational_value(gain.metadata.gain_min) : 0;
    result.gain_max = explicit_gain ? rational_value(gain.metadata.gain_max) : 0;
    // Rendering is complete; release both decoded planes before the encoder
    // allocates its own base, gain map, and output buffer.
    staged.image.linear_p3 = {};
    staged.image.authored_sdr.reset();
    const auto processed = Clock::now();

    check_cancelled();
    if (sink) {
      const auto path = path_utf8(result.input);
      sink->on_progress({"encode", path, .7, {}});
    }
    check_cancelled();
    auto bytes = encode_for(photo, gain, staged.image.metadata, options);
    const auto codec_finished = Clock::now();
    photo = {};
    gain = {};  // Free the float base and gain before the decoder allocates.
    if (options.verify_output) {
      if (sink) {
        const auto path = path_utf8(result.input);
        sink->on_progress({"verify", path, .9, {}});
      }
      check_cancelled();
      verify_encoded(bytes, options);
      result.self_verified = true;
    }
    const auto verification_finished = Clock::now();
    if (input_stamp(result.input) != staged.input_stamp) {
      throw std::runtime_error("input changed during conversion");
    }
    // --skip-existing means "keep this exact render if current, otherwise
    // replace it". A stale or provenance-less output must therefore be
    // publishable even when the user did not also spell --overwrite.
    check_cancelled();
    write_binary_file_atomic(result.output, bytes,
                             options.overwrite || options.skip_existing);
    const auto encoded = Clock::now();
    result.decode_ms = staged.decode_ms;
    result.process_ms = milliseconds(decoded, processed);
    result.encode_ms = milliseconds(processed, encoded);
    result.codec_ms = milliseconds(processed, codec_finished);
    result.verify_ms = milliseconds(codec_finished, verification_finished);
    result.write_ms = milliseconds(verification_finished, encoded);
    result.success = true;
    result.message = "ok";
    write_resume_state(result.output, result.input, staged.input_stamp, options, fingerprint);
  } catch (const Cancelled&) {
    throw;
  } catch (const ExportDimensionLimit& e) {
    result.success = false;
    result.error_code = "export_dimension_limit";
    result.detail = e.what();
    result.message = e.what();
  } catch (const std::bad_alloc&) {
    result.success = false;
    result.message = options.decode_intent == DecodeIntent::Export
                         ? "insufficient memory for full-resolution export"
                         : "insufficient memory for preview export";
  } catch (const std::exception& e) {
    result.success = false;
    result.message = e.what();
  }
}

// Distinct inputs that would land on the same output would race, and the winner
// would be arbitrary. Detected before any work starts.
void check_output_collisions(const std::vector<std::filesystem::path>& files,
                             const ConvertOptions& options) {
  std::set<PathKey> outputs;
  for (const auto& file : files) {
    const auto output = output_path_for(file, options);
    if (!outputs.insert(path_key(output)).second) {
      throw std::runtime_error("multiple inputs map to the same output: " +
                               path_utf8(output));
    }
  }
  if (options.report_path.empty()) return;
  const auto report = path_key(options.report_path);
  if (outputs.contains(report)) {
    throw std::runtime_error("report path collides with an image output");
  }
  for (const auto& file : files) {
    if (path_key(file) == report) {
      throw std::runtime_error("report path collides with an input image");
    }
  }
}

}  // namespace

void require_decode_resolution(const ConvertOptions& options,
                               const DecodeInfo& decode) {
  if (options.decode_intent == DecodeIntent::Export &&
      decode.resolution_reduced) {
    throw std::runtime_error(
        "full-resolution export produced a reduced-resolution decode");
  }
}

FileResult convert_file(const std::filesystem::path& input,
                        const ConvertOptions& requested_options,
                        const std::string& fingerprint, ProgressSink* sink) {
  auto options = requested_options;
  options.raw.progress_sink = sink;
  const bool resources_unprepared =
      (!options.color_lut.path.empty() && !options.color_lut.snapshot) ||
      (!options.external_gain_path.empty() && !options.external_gain_snapshot);
  const bool frame_prepared = options.frame_snapshot != nullptr;
  prepare_frame_snapshot(options);
  prepare_conversion_resources(options);
  apply_output_color_options(options);
  // run_conversion passes the fingerprint of its shared snapshot. Standalone
  // callers must fingerprint the resources captured here, not an earlier read.
  const auto captured_fingerprint = resources_unprepared || (!frame_prepared && options.frame_snapshot)
      ? settings_fingerprint(options) : fingerprint;
  auto staged = decode_stage(input, options, captured_fingerprint);
  check_cancelled();
  if (sink && staged.decoded) {
    const auto path = path_utf8(input);
    sink->on_progress({"process", path, .3, {}});
  }
  finish_stage(staged, options, captured_fingerprint, sink);
  return staged.result;
}

FrameSpec read_frame_spec(const std::filesystem::path& path) {
  return configuration_resource([&] {
    const auto bytes = read_binary_file(path);
    auto frame = parse_frame_spec(json::parse(std::string_view(
        reinterpret_cast<const char*>(bytes.data()), bytes.size())), path.parent_path());
    validate_frame_resources(frame);
    return frame;
  });
}

void validate_frame_resources(const FrameSpec& frame) {
  if (frame.overlay.empty()) return;
  std::error_code error;
  if (!std::filesystem::is_regular_file(frame.overlay, error) ||
      !std::ifstream(frame.overlay, std::ios::binary).is_open()) {
    throw std::invalid_argument("frame: overlay is not a readable regular file: " + path_utf8(frame.overlay));
  }
}

int run_conversion(const ConvertOptions& requested_options, ProgressSink* sink, std::string* report) {
  check_cancelled();
  auto options = requested_options;
  options.raw.progress_sink = sink;
  prepare_frame_snapshot(options);
  apply_output_color_options(options);
  // Validate the paths first so missing or invalid resources keep their
  // messages and precedence, then capture them before any callback.
  validate_convert_options(options);
  prepare_conversion_resources(options);
  const auto files = discover_input_files(options);
  check_output_collisions(files, options);

  std::filesystem::create_directories(options.output_directory);
  if (!options.decode_cache_directory.empty()) {
    std::filesystem::create_directories(options.decode_cache_directory);
    prune_decode_cache(options.decode_cache_directory, options.decode_cache_budget_bytes);
  }

  const auto fingerprint = settings_fingerprint(options);
  std::vector<FileResult> results(files.size());
  const auto announce = [&](const FileResult& result,
                            const std::filesystem::path& file) {
    if (!sink) return;
    std::ostringstream text;
    text << (result.skipped ? "skip: " : (result.success ? "ok: " : "error: "))
              << path_utf8(file);
    if (!result.success) text << ": " << result.message;
    text << '\n';
    // A degraded decode still succeeds for non-resolution conditions such as
    // rejected crop metadata. Resolution is not a degradable export property:
    // RAW half-size is selected explicitly by preview callers only.
    if (result.success && result.decode_degraded) {
      text << "warning: " << path_utf8(file) << ": ";
      // Only phrase this as a shortfall against the target when the target was
      // actually applied; otherwise target_* is the request that was refused
      // and comparing the two would read as a resolution loss it is not. A
      // degradation that left the geometry alone (no camera matrix, an SDR
      // fallback) is not described as one at all.
      if (!result.target_dimensions_applied) {
        text << "decoded at " << result.decoded_width << 'x' << result.decoded_height
                  << ", ignoring the recorded " << result.target_width << 'x'
                  << result.target_height << " crop";
      } else if (result.decoded_width != result.target_width ||
                 result.decoded_height != result.target_height) {
        text << "decoded at " << result.decoded_width << 'x' << result.decoded_height
                  << " instead of " << result.target_width << 'x' << result.target_height;
      } else {
        text << "decode degraded";
      }
      text << " (";
      for (std::size_t i = 0; i < result.decode_degradation_reasons.size(); ++i) {
        if (i != 0) text << ", ";
        text << result.decode_degradation_reasons[i];
      }
      text << ")\n";
    }
    const auto path = path_utf8(file);
    const auto message = text.str();
    sink->on_progress({result.success ? "complete" : "error", path, 1.0, message});
  };

  for (std::size_t index = 0; index < files.size(); ++index) {
    check_cancelled();
    const auto path = path_utf8(files[index]);
    if (sink) sink->on_progress({"decode", path, 0.0, {}});
    results[index] = convert_file(files[index], options, fingerprint, sink);
    announce(results[index], files[index]);
  }
  check_cancelled();
  write_run_report(options.report_path, results, options);
  if (report) *report = run_report_json(results, options);
  return std::all_of(results.begin(), results.end(),
                     [](const FileResult& r) { return r.success; })
             ? 0
             : 1;
}

}  // namespace hyperdr
