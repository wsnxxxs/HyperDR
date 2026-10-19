#include "engine_internal.hpp"
#include "preview_binary.hpp"

#include "hyperdr/app/analysis_cache.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/preview.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/app/source_defaults.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/gainmap/rendition.hpp"
#include "hyperdr/image/resample.hpp"

#include <cmath>
#include <memory>
#include <utility>

namespace hyperdr {

FloatImage crop_preview_plane(const FloatImage& image, const PreviewRegion& region) {
  if (image.pixels.empty()) return {};
  FloatImage cropped(*region.width, *region.height, image.channels);
  const auto row_samples = static_cast<std::size_t>(*region.width) * image.channels;
  for (std::uint32_t y = 0; y < *region.height; ++y) {
    check_cancelled();
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

PreviewPixels photo_preview_frame(PhotoRenditions result,
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
  const auto defaults = source_defaults(input.domain);
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.native-preview/v1")
      .member("width", result.sdr.width)
      .member("height", result.sdr.height)
      .member("sourceWidth", decode.source_width ? decode.source_width : result.sdr.width)
      .member("sourceHeight", decode.source_height ? decode.source_height : result.sdr.height)
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
  if(decode.raw) writer.begin_object("raw").member("supported",true)
      .member("lensCorrectionSupported",decode.raw->lens_correction_supported)
      .member("decoderVersion",decode.raw->decoder_version).member("osBuild",raw_os_build()).end_object();
  writer.begin_array("degradationReasons");
  for (const auto& reason : decode.degradation_reasons) writer.element(reason);
  writer.end_array().end_object();
  const std::string metadata = writer.take();

  auto hdr_pixels = result.hdr.pixels.empty() ? result.sdr : std::move(result.hdr);
  return {metadata, std::move(result.sdr), std::move(hdr_pixels), false};
}

PreviewPixels native_preview_frame(GainMapResult result,
    const DecodeInfo& decode, const InputDescription& input, bool hasCaptureMetadata,
    const SourceColorInfo& source_color) {
  return photo_preview_frame(renditions_from_gain_map(std::move(result)), decode, input,
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

struct PreviewSession::State {
  std::vector<std::unique_ptr<PreviewSource>> sources;
  std::vector<std::pair<std::string, DecodedImage>> raw_masters;
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
    if (is_raw_extension(lower_extension(options.input))) {
      const auto cache_file = options.decode_cache_directory.empty()
          ? std::filesystem::path{} : decode_cache_path(options.decode_cache_directory, key);
      if (!cache_file.empty()) {
        source->analysis_file = cache_file.parent_path() /
            (cache_file.stem().string() + ".analysis.hdrcache");
      }
      const bool disk_hit = !cache_file.empty() && read_decode_cache(cache_file, source->image);
      if (!disk_hit) {
        // One CIRAWFilter render per scale bucket serves all bounded edges.
        auto master_options = options;
        master_options.preview_max_edge = 0;
        // Preserve the RAW scale bucket while removing the final bounded resize.
        const auto master_key = decode_cache_key(options.input,
            decode_cache_variant(master_options, master_options.raw),
            options.decode_cache_source_sha256);
        // A full-size detail source is itself the scale-1 master. Reuse it
        // rather than retaining two complete copies of a 61MP decode.
        const auto full_source=std::find_if(sources.begin(),sources.end(),
            [&](const auto& item){return item->key==master_key;});
        if(full_source!=sources.end()) {
          source->image=(*full_source)->image;
        } else {
          auto master=std::find_if(raw_masters.begin(),raw_masters.end(),
              [&](const auto& item){return item.first==master_key;});
          if(master==raw_masters.end()) {
            master_options.decode_cache_directory.clear();
            raw_masters.emplace_back(master_key,
                decode_cached_image(options.input,master_options,master_options.raw));
          } else {
            auto hit=std::move(*master);raw_masters.erase(master);raw_masters.push_back(std::move(hit));
          }
          if(options.preview_max_edge==0) {
            source->image=std::move(raw_masters.back().second);
            raw_masters.pop_back();
          } else source->image=raw_masters.back().second;
        }
        source->image.transform_planes([&](FloatImage plane) {
          return resample_to_max_edge(std::move(plane), options.preview_max_edge);
        });
        if (!cache_file.empty()) {
          static_cast<void>(write_decode_cache(cache_file, source->image,
              options.decode_cache_budget_bytes));
        }
      }
    } else {
      raw_masters.clear();
      source->image = decode_cached_image(options.input, options, options.raw, &source->analysis_file);
    }
    if (source->image.domain == InputDomain::kSceneReferred) {
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
    for (const auto& item : raw_masters) retained += item.second.linear_p3.pixels.size()*sizeof(float);
    while (sources.size() > 1 && (sources.size() > 3 || retained > kDecodedBudget)) {
      retained -= decoded_bytes(*sources.front());
      sources.erase(sources.begin());
    }
    while(raw_masters.size()>1 && retained>kDecodedBudget) {
      retained-=raw_masters.front().second.linear_p3.pixels.size()*sizeof(float);
      raw_masters.erase(raw_masters.begin());
    }
    return *sources.back();
  }
};

PreviewSession::PreviewSession(std::filesystem::path source, std::string sha256, EngineConfig config)
    : state_(std::make_unique<State>()), source_(std::move(source)),
      sha256_(std::move(sha256)), config_(std::move(config)) {}
PreviewSession::~PreviewSession() { release_apple_raw_cache(source_); }

PreviewPixels PreviewSession::render_pixels(ConvertOptions options, PreviewRegion region,
    const CancelToken* cancel, bool compact) {
  std::unique_lock lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) throw Busy();
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  check_cancelled();
  if (!source_.empty()) options.input = source_;
  prepare_conversion_resources(options);
  options.decode_intent = DecodeIntent::Preview;
  options.decode_cache_source_sha256 = sha256_;
  if (options.decode_cache_directory.empty()) options.decode_cache_directory = config_.cache_directory;
  apply_output_color_options(options);
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
  auto& cached = state_->decode(options);
  auto& decoded = cached.image;
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
  const auto frame_from_photo = [&](PhotoRenditions photo) {
    if (detail) photo = crop_preview_photo(std::move(photo), region);
    return photo_preview_frame(std::move(photo), decoded.decode, input, hasCaptureMetadata,
        decoded.source_color,
        detail ? &region : nullptr, full_width, full_height);
  };
  const auto release_detail_render_cache = [&] {
    if (!detail) return;
    // Panning needs the full decoder result, not several full-resolution
    // rendered copies. Rebuild adjustment-specific intermediates on demand.
    cached.preparation = {};
    cached.model_base = {};
    cached.model_input = {};
    cached.prediction = {};
    cached.model_key.clear();
  };
  GainMapResult result;
  if (!options.ai_model_path.empty()) {
    const auto* analysis = input.domain == InputDomain::kSceneReferred
        ? &cached.analysis : nullptr;
    // The model id is part of the cache key, not just the request: without it a
    // cached model-1 base would be reused for model 2 and the preview would show
    // the previous model's picture under the new model's name.
    const auto model_key = selected_native_model_id(options) +
                           (options.clamp_srgb ? "/srgb" : "/p3");
    const auto request = native_model_request(options, decoded.metadata);
    if (is_sdr_encoding(options.encoding)) {
      result = render_native_model_base(decoded, options.clamp_srgb, analysis);
    } else {
      if (cached.model_key != model_key) {
        cached.model_base = render_native_model_base(decoded, options.clamp_srgb, analysis);
        cached.model_input = make_native_model_input(cached.model_base.base_linear);
        cached.prediction = infer_native_model(request, cached.model_input);
        cached.model_key = model_key;
      }
      result = cached.model_base;
      apply_native_model_gain_map(result, cached.model_input, cached.prediction,
                                  options.gain.gain_strength, options.ai_post);
    }
  } else if (!options.external_gain_path.empty()) {
    auto external = options.external_gain_snapshot ? parse_external_gain_map(options.external_gain_snapshot->gain_bytes,
        options.external_gain_snapshot->report_bytes, options.allow_legacy_external_gain) : read_external_gain_map(
        options.external_gain_path, options.external_gain_report,
        options.allow_legacy_external_gain);
    const auto development = replay_external_development(
        external, options.input, decoded, options);
    result = make_external_gain_map(decoded.linear_p3, std::move(external),
                                    development, decoded.capture,
                                    decoded.describe_input());
  } else {
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
    if (cached.preparation_key != identity) {
      cached.preparation = {};
      cached.preparation_key = identity;
    }
    auto photo=render_graded_photo(decoded.linear_p3,options.gain,decoded.capture,input,
        is_sdr_encoding(options.encoding) ? RenderTarget::Sdr : RenderTarget::Hdr,
        options.color_lut, nullptr,
        input.domain==InputDomain::kSceneReferred ? &cached.analysis : nullptr,
        &cached.preparation);
    if (is_sdr_encoding(options.encoding) &&
        resolved_sdr_gamut(options) == ColorGamut::kSrgb) fit_sdr_to_srgb(photo.sdr);
    if(options.encoding == OutputEncoding::Adaptive ||
        (options.encoding == OutputEncoding::IsoGainMapJpeg && photo.hdr_is_source)) {
      result=gain_map_from_renditions(std::move(photo),
          options.encoding == OutputEncoding::IsoGainMapJpeg ? GainMapWriterProfile::iso_generic
                                                      : GainMapWriterProfile::apple_strict);
    }
    else {
      validate_encoding_headroom(options.encoding,photo.stats.headroom_stops);
      auto pixels=frame_from_photo(std::move(photo));
      release_detail_render_cache();
      check_cancelled();
      return pixels;
    }
  }
  if(!options.ai_model_path.empty() || !options.external_gain_path.empty()) {
    if(!options.color_lut.path.empty() || !is_gain_map_encoding(options.encoding)) {
      auto photo=render_graded_gain_map(result, options.color_lut, !is_sdr_encoding(options.encoding));
      if (is_sdr_encoding(options.encoding) &&
          resolved_sdr_gamut(options) == ColorGamut::kSrgb) fit_sdr_to_srgb(photo.sdr);
      if(is_gain_map_encoding(options.encoding)) result.base_linear=std::move(photo.sdr);
      else {
        auto pixels=frame_from_photo(std::move(photo));
        release_detail_render_cache();
        check_cancelled();
        return pixels;
      }
    }
  }
  validate_encoding_headroom(options.encoding, result.headroom_stops);
  if (detail) {
    auto pixels = frame_from_photo(renditions_from_gain_map(std::move(result)));
    release_detail_render_cache();
    check_cancelled();
    return pixels;
  }
  check_cancelled();
  if (compact && !result.clamp_srgb && result.gain_map.channels == 1) {
    auto metadata = compact_preview_metadata(result, decoded.decode, input, hasCaptureMetadata, decoded.source_color);
    return {std::move(metadata), std::move(result.base_linear), std::move(result.gain_map), true};
  }
  return native_preview_frame(std::move(result), decoded.decode, input, hasCaptureMetadata, decoded.source_color);
}

std::vector<std::uint8_t> PreviewSession::render(ConvertOptions options, PreviewRegion region,
    const CancelToken* cancel, bool compact) {
  const auto frame = render_pixels(std::move(options), std::move(region), cancel, compact);
  CancelScope cancellation(cancel);
  std::vector<std::uint8_t> bytes{'H', 'Y', 'P', 'R', 'E', 'V', frame.compact ? std::uint8_t{'2'} : std::uint8_t{'1'}, '\n'};
  bytes.reserve(12 + frame.metadata.size() + (frame.base.pixels.size() + frame.gain.pixels.size()) * sizeof(float));
  append_u32_le(bytes, static_cast<std::uint32_t>(frame.metadata.size()));
  bytes.insert(bytes.end(), frame.metadata.begin(), frame.metadata.end());
  append_float_image(bytes, frame.base);
  append_float_image(bytes, frame.gain);
  check_cancelled();
  return bytes;
}

std::vector<std::uint8_t> PreviewSession::model_gain(ConvertOptions options, const CancelToken* cancel) {
  std::unique_lock lock(mutex_, std::try_to_lock);
  if (!lock.owns_lock()) throw Busy();
  CancelScope cancellation(cancel);
  ExecutionScope execution({config_.heic_tile_workers, config_.memory_budget_bytes});
  check_cancelled();
  options.input = source_;
  options.decode_cache_source_sha256 = sha256_;
  if (options.decode_cache_directory.empty()) options.decode_cache_directory = config_.cache_directory;
  auto packet = render_model_gain(std::move(options), [&](const ConvertOptions& prepared) -> const DecodedImage& {
    return state_->decode(prepared).image;
  });
  check_cancelled();
  return packet;
}

}  // namespace hyperdr
