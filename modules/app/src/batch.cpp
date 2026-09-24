#include "hyperdr/image/dcp_profile.hpp"
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
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/gainmap/native_model.hpp"

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <iostream>
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

bool half_size_matches_full(std::uint32_t half, std::uint32_t full) {
  return half != 0 && full != 0 &&
         (full == half * 2U || full + 1U == half * 2U);
}

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
  if (!image.raw_profile && !analysis_cache.empty() && image.describe_input().domain == InputDomain::kSceneReferred) {
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
      return "raw-neutral-v1";
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
  if (image.raw_profile || image.describe_input().domain == InputDomain::kDisplayReferredSdr) {
    development.gain_strength = 0.0F;
  }
  return make_gain_map(image.linear_p3, development, image.capture,
      image.describe_input(), image.raw_profile ? nullptr : analysis);
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
  if (sha256_file_hex(input) != binding.source_sha256) {
    reject("source sha256");
  }
  if (binding.preprocessing_fingerprint != model_preprocessing_fingerprint(options)) {
    reject("preprocessing changed; regenerate the model input and gain");
  }
  if (binding.highlight_recovery !=
      highlight_recovery_name(options.raw.highlight_recovery)) {
    reject("highlight recovery");
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
       image.domain == InputDomain::kDisplayReferredHdr) && !image.raw_profile &&
      binding.delivered_crop_width == decoded.target_width &&
      binding.delivered_crop_height == decoded.target_height &&
      raster_preview_matches_full(decoded);
  const bool delivered_matches = raster_preview || (binding.raw_half_size
      ? (options.decode_intent == DecodeIntent::Preview && same_delivered_size) ||
            (half_size_matches_full(binding.delivered_crop_width,
                                    decoded.decoded_width) &&
             half_size_matches_full(binding.delivered_crop_height,
                                    decoded.decoded_height))
      : same_delivered_size ||
            (options.decode_intent == DecodeIntent::Preview && options.raw.half_size &&
             half_size_matches_full(decoded.decoded_width, binding.delivered_crop_width) &&
             half_size_matches_full(decoded.decoded_height, binding.delivered_crop_height)));
  if (!delivered_matches) reject("delivered crop");

  const auto profile_hash = image.raw_profile ? image.raw_profile->profile->sha256 : std::string{};
  if (binding.raw_profile_sha256 != profile_hash) reject("RAW DCP profile");
  const auto lens_hash = image.raw_lens_profile_path.empty() ? std::string{} : sha256_file_hex(image.raw_lens_profile_path);
  if (binding.raw_lens_profile_sha256 != lens_hash) reject("RAW LCP profile");
  const auto expected_recipe = image.raw_profile ? "raw-dcp-v1" :
      native_model_development_kind(image.describe_input().domain);
  const bool legacy_scene_recipe = binding.recipe.id == "photographic-v1" &&
      image.describe_input().domain == InputDomain::kSceneReferred && !image.raw_profile;
  if (binding.recipe.id != expected_recipe && !legacy_scene_recipe)
    reject("development recipe does not match the decoded input domain");
  GainMapOptions replay = options.gain;
  replay.auto_exposure = false;
  replay.exposure_ev = binding.recipe.exposure_ev;
  if (image.raw_profile) replay.exposure_ev -= image.raw_profile->baseline_exposure +
      image.raw_profile->profile->baseline_exposure_offset;
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
    }

    staged.image = decode_cached_image(path, options, raw, &staged.analysis_cache);
    staged.decode_ms = milliseconds(start, Clock::now());
    staged.decoded = true;
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
    case HdrEncoding::UltraHdr:
      if (images.gain_map.pixels.empty()) {
        return encode_ultrahdr_jpeg(photo, metadata, options.quality);
      }
      return encode_ultrahdr_jpeg(images, metadata, options.quality);
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
  else if (options.encoding == HdrEncoding::UltraHdr) verify_ultrahdr_jpeg(bytes);
  else if (is_avif_encoding(options.encoding)) verify_avif_decodable(bytes);
  else verify_heic_decodable(bytes, options.encoding);
}

void finish_stage(Staged& staged, const ConvertOptions& options,
                  const std::string& fingerprint) {
  if (!staged.decoded) return;
  auto& result = staged.result;
  try {
    const auto decoded = Clock::now();
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
      external = read_external_gain_map(options.external_gain_path,
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
    if (is_sdr_encoding(options.encoding) && resolved_sdr_gamut(options) == ColorGamut::kSrgb)
      fit_sdr_to_srgb(photo.sdr);
    const bool codec_gain = options.encoding == OutputEncoding::UltraHdr &&
        options.ai_model_path.empty() && !external && !photo.hdr_is_source;
    const bool explicit_gain = is_gain_map_encoding(options.encoding) && !codec_gain;
    if (explicit_gain) {
      if (options.ai_model_path.empty() && !external) {
        gain = gain_map_from_renditions(std::move(photo),
            options.encoding == OutputEncoding::UltraHdr ? GainMapWriterProfile::iso_generic
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
    result.raw_white_balance = staged.image.raw_white_balance;
    result.raw_color_matrix = staged.image.raw_color_matrix;
    result.raw_lens_profile = path_utf8(staged.image.raw_lens_profile_path);
    result.raw_lens_correction = staged.image.raw_lens_correction;
    if (staged.image.raw_profile) {
      const auto& context = *staged.image.raw_profile;
      const auto& profile = *context.profile;
      result.raw_profile_name = profile.name;
      result.raw_profile_sha256 = profile.sha256;
      result.raw_profile_camera = profile.camera_model;
      result.raw_profile_tone = profile.tone_curve.empty() ? "adobe-sdk-acr3" : "profile";
      result.raw_profile_baseline_ev = context.baseline_exposure + profile.baseline_exposure_offset;
    }
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
                                   : staged.image.raw_profile ? "raw-dcp-v1" : native_model_development_kind(
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

    auto bytes = encode_for(photo, gain, staged.image.metadata, options);
    if (codec_gain) {
      const auto info = probe_ultrahdr_jpeg(bytes);
      result.codec_gain = true;
      result.gain_min = result.stats.gain_min_stops = *std::min_element(info.gain_min.begin(), info.gain_min.end());
      result.gain_max = result.stats.gain_max_stops = *std::max_element(info.gain_max.begin(), info.gain_max.end());
      result.stats.gain_gamma = info.gamma[0]; // XMP writer uses shared channel metadata.
      result.headroom_stops = info.headroom_stops;
    }
    const auto codec_finished = Clock::now();
    photo = {};
    gain = {};  // Free the float base and gain before the decoder allocates.
    if (options.verify_output) {
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
                        const std::string& fingerprint) {
  auto options = requested_options;
  apply_output_color_options(options);
  auto staged = decode_stage(input, options, fingerprint);
  finish_stage(staged, options, fingerprint);
  return staged.result;
}

int run_conversion(const ConvertOptions& requested_options) {
  auto options = requested_options;
  apply_output_color_options(options);
  validate_convert_options(options);
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
    std::cerr << (result.skipped ? "skip: " : (result.success ? "ok: " : "error: "))
              << path_utf8(file);
    if (!result.success) std::cerr << ": " << result.message;
    std::cerr << '\n';
    // A degraded decode still succeeds for non-resolution conditions such as
    // rejected crop metadata. Resolution is not a degradable export property:
    // RAW half-size is selected explicitly by preview callers only.
    if (result.success && result.decode_degraded) {
      std::cerr << "warning: " << path_utf8(file) << ": ";
      // Only phrase this as a shortfall against the target when the target was
      // actually applied; otherwise target_* is the request that was refused
      // and comparing the two would read as a resolution loss it is not. A
      // degradation that left the geometry alone (no camera matrix, an SDR
      // fallback) is not described as one at all.
      if (!result.target_dimensions_applied) {
        std::cerr << "decoded at " << result.decoded_width << 'x' << result.decoded_height
                  << ", ignoring the recorded " << result.target_width << 'x'
                  << result.target_height << " crop";
      } else if (result.decoded_width != result.target_width ||
                 result.decoded_height != result.target_height) {
        std::cerr << "decoded at " << result.decoded_width << 'x' << result.decoded_height
                  << " instead of " << result.target_width << 'x' << result.target_height;
      } else {
        std::cerr << "decode degraded";
      }
      std::cerr << " (";
      for (std::size_t i = 0; i < result.decode_degradation_reasons.size(); ++i) {
        if (i != 0) std::cerr << ", ";
        std::cerr << result.decode_degradation_reasons[i];
      }
      std::cerr << ")\n";
    }
  };

  for (std::size_t index = 0; index < files.size(); ++index) {
    results[index] = convert_file(files[index], options, fingerprint);
    announce(results[index], files[index]);
  }
  write_run_report(options.report_path, results, options);
  return std::all_of(results.begin(), results.end(),
                     [](const FileResult& r) { return r.success; })
             ? 0
             : 1;
}

}  // namespace hyperdr
