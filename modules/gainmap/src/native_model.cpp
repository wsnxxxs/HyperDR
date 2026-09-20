#include "hyperdr/gainmap/native_model.hpp"

#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/external.hpp"
#include "hyperdr/gainmap/gain_map.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/resample.hpp"
#include "hyperdr/look/filter.hpp"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <utility>
#include <vector>

namespace hyperdr {
namespace {

//: The offset the research reconstruction adds to the base before applying the
//: gain (`src/hdr_core.py::reconstruct` uses 1e-5). It is carried on the model
//: rather than applied globally because the incumbent model was trained with a
//: zero offset and changing it would alter its output.
constexpr Rational kResearchBaseOffset{1, 100000};

NativeModelInfer& runtime_slot() {
  static NativeModelInfer runtime;
  return runtime;
}

std::mutex& runtime_mutex() {
  static std::mutex mutex;
  return mutex;
}

std::uint32_t align_stride16(std::uint32_t value) {
  if (value == 0) return kNativeModelStride;
  if (value > std::numeric_limits<std::uint32_t>::max() -
                 (kNativeModelStride - 1U)) {
    throw std::length_error("native model dimensions overflow stride alignment");
  }
  return std::max<std::uint32_t>(
      kNativeModelStride,
      ((value + kNativeModelStride - 1U) / kNativeModelStride) *
          kNativeModelStride);
}

void validate_post_options_impl(const NativeModelPostOptions& post) {
  if (!(std::isfinite(post.brightness_ev) && post.brightness_ev >= -8.0F &&
        post.brightness_ev <= 8.0F)) {
    throw std::invalid_argument("AI brightness must be in [-8, 8] EV");
  }
  if (!(std::isfinite(post.contrast) && post.contrast >= 0.1F &&
        post.contrast <= 4.0F)) {
    throw std::invalid_argument("AI contrast must be in [0.1, 4]");
  }
  if (!(std::isfinite(post.shadows_ev) && post.shadows_ev >= -8.0F &&
        post.shadows_ev <= 8.0F)) {
    throw std::invalid_argument("AI shadows must be in [-8, 8] EV");
  }
  if (!(std::isfinite(post.highlights_stops) &&
        post.highlights_stops >= -8.0F && post.highlights_stops <= 8.0F)) {
    throw std::invalid_argument("AI highlights must be in [-8, 8] stops");
  }
  if (!(std::isfinite(post.hdr_range_stops) &&
        (post.hdr_range_stops < 0.0F || post.hdr_range_stops <= 16.0F))) {
    throw std::invalid_argument("AI HDR range must be negative or in [0, 16]");
  }
  if (!(std::isfinite(post.expansion_start) &&
        (post.expansion_start < 0.0F || post.expansion_start <= 1.0F))) {
    throw std::invalid_argument(
        "AI expansion start must be negative or in [0, 1]");
  }
}

void validate_model_input(const FloatImage& input) {
  input.require_consistent("native model input");
  if (input.channels != 3 || input.width == 0 || input.height == 0) {
    throw std::invalid_argument(
        "native model input must be a non-empty RGB image");
  }
  if (input.width % kNativeModelStride != 0 ||
      input.height % kNativeModelStride != 0) {
    throw std::invalid_argument(
        "native model input dimensions must be stride-16 aligned");
  }
  for (const float value : input.pixels) {
    if (!std::isfinite(value) || value < 0.0F || value > 1.0F) {
      throw std::invalid_argument(
          "native model input must be finite linear SDR in [0, 1]");
    }
  }
}

void validate_model_output(const FloatImage& input,
                           const NativeModelOutput& output) {
  output.signed_log2_gain.require_consistent("native model output");
  if (output.signed_log2_gain.channels != 1) {
    throw std::invalid_argument("native model output must be single-channel");
  }
  const auto expected_width = input.width / kNativeModelStride;
  const auto expected_height = input.height / kNativeModelStride;
  if (output.signed_log2_gain.width != expected_width ||
      output.signed_log2_gain.height != expected_height) {
    throw std::invalid_argument(
        "native model output dimensions do not match stride-16 input");
  }
  for (const float value : output.signed_log2_gain.pixels) {
    if (!std::isfinite(value) || value < -64.0F || value > 64.0F) {
      throw std::invalid_argument(
          "native model output must be finite signed log2 gain in [-64, 64]");
    }
  }
}

constexpr std::uint32_t kNativeMetadataDenominator = 1000000U;

Rational outward_gain_min(float value) {
  return {static_cast<std::int32_t>(std::floor(
              static_cast<double>(value) * kNativeMetadataDenominator)),
          kNativeMetadataDenominator};
}

Rational outward_gain_max(float value) {
  return {static_cast<std::int32_t>(std::ceil(
              static_cast<double>(value) * kNativeMetadataDenominator)),
          kNativeMetadataDenominator};
}

void adjust_base(GainMapResult& result, const NativeModelPostOptions& post) {
  if (result.base_linear.channels != 3) {
    throw std::invalid_argument("native model result base must be RGB");
  }
  const bool change = std::abs(post.brightness_ev) > 1.0e-8F ||
                      std::abs(post.contrast - 1.0F) > 1.0e-8F ||
                      std::abs(post.shadows_ev) > 1.0e-8F;
  if (!change) return;

  const float brightness = std::exp2(post.brightness_ev);
  parallel_for_rows(result.base_linear.height, [&](const std::uint32_t y) {
    for (std::uint32_t x = 0; x < result.base_linear.width; ++x) {
      const auto index =
          (static_cast<std::size_t>(y) * result.base_linear.width + x) * 3U;
      float r = std::max(0.0F, result.base_linear.pixels[index]);
      float g = std::max(0.0F, result.base_linear.pixels[index + 1]);
      float b = std::max(0.0F, result.base_linear.pixels[index + 2]);
      const float luma = p3_luminance(r, g, b);
      const float shadow_weight = 1.0F - smoothstep(0.03F, 0.55F, luma);
      const float shadow_scale =
          std::exp2(post.shadows_ev * shadow_weight);
      float target = luma * brightness * shadow_scale;
      if (post.contrast != 1.0F && target > 0.0F) {
        target = 0.18F * std::pow(
                             std::max(target / 0.18F, 0.0F), post.contrast);
      }
      const float scale = luma > 1.0e-8F ? target / luma : 0.0F;
      r = std::clamp(r * scale, 0.0F, 1.0F);
      g = std::clamp(g * scale, 0.0F, 1.0F);
      b = std::clamp(b * scale, 0.0F, 1.0F);
      result.base_linear.pixels[index] = r;
      result.base_linear.pixels[index + 1] = g;
      result.base_linear.pixels[index + 2] = b;
    }
  });
}

}  // namespace

const std::vector<NativeModelDescriptor>& native_model_table() {
  static const std::vector<NativeModelDescriptor> table{
      {kResearchCnnModelId, "纯 CNN", "model.research-cnn-v1",
       "research-demo-fold0-seed908/v1", {}, false, true},
      {kResearchExifModelId, "EXIF 参数辅助预测", "model.research-exif-v1",
       "research-demo-fold0-seed908/v1", kResearchCnnModelId, true, true},
  };
  return table;
}

bool native_model_id_known(std::string_view requested) {
  for (const auto& descriptor : native_model_table()) {
    if (descriptor.id == requested) return true;
  }
  return false;
}

std::string normalize_native_model_id(std::string_view requested) {
  // Default to CNN when the caller does not select a model.
  if (requested.empty() || requested == kEmbeddedNativeModel) {
    return std::string(kResearchCnnModelId);
  }
  if (native_model_id_known(requested)) return std::string(requested);
  std::string message("unknown AI model id '");
  message.append(requested);
  message += "'; known ids are";
  for (const auto& descriptor : native_model_table()) {
    message += " ";
    message += descriptor.id;
  }
  throw std::invalid_argument(message);
}

const NativeModelDescriptor& native_model_descriptor(std::string_view canonical_id) {
  for (const auto& descriptor : native_model_table()) {
    if (descriptor.id == canonical_id) return descriptor;
  }
  throw std::invalid_argument("not a canonical AI model id: " +
                              std::string(canonical_id));
}

std::string native_model_list_json() {
  // `available` is a per-build fact: without the ncnn adapter the table still
  // describes the options, but none of them can run.
  const bool available = native_model_runtime_available();
  json::Writer writer;
  writer.begin_object()
      .member("schema", "hyperdr.model-list/v1")
      .member("runtimeAvailable", available)
      .member("defaultModelId", std::string(kResearchCnnModelId))
      .begin_array("models");
  for (const auto& descriptor : native_model_table()) {
    writer.begin_object()
        .member("id", std::string(descriptor.id))
        .member("displayName", std::string(descriptor.display_name))
        .member("displayKey", std::string(descriptor.display_key))
        .member("version", std::string(descriptor.version))
        .member("available", available)
        .member("requiresExif", descriptor.requires_capture)
        .member("fallbackModelId", std::string(descriptor.fallback_id))
        .end_object();
  }
  writer.end_array().end_object();
  return writer.take();
}

CaptureParameters capture_parameters_from_metadata(const CaptureMetadata& capture) {
  CaptureParameters parameters;
  const auto copy = [](const std::optional<float>& value) -> std::optional<double> {
    if (!value.has_value() || !std::isfinite(*value)) return std::nullopt;
    return static_cast<double>(*value);
  };
  parameters.iso = copy(capture.iso);
  parameters.exposure_seconds = copy(capture.exposure_time_seconds);
  parameters.f_number = copy(capture.aperture_f_number);
  parameters.exposure_bias_ev = copy(capture.exposure_bias_ev);
  parameters.focal_length_mm = copy(capture.focal_length_mm);
  parameters.focal_length_35mm = copy(capture.focal_length_35mm);
  return parameters;
}

NativeModelOutput make_native_model_output(std::string_view requested_id,
                                           std::string_view effective_id,
                                           std::string_view inference_mode,
                                           std::string fallback_reason,
                                           FloatImage signed_log2_gain) {
  const auto requested = normalize_native_model_id(requested_id);
  const auto effective = normalize_native_model_id(effective_id);
  const auto& descriptor = native_model_descriptor(effective);
  NativeModelOutput output;
  output.signed_log2_gain = std::move(signed_log2_gain);
  output.requested_model_id = requested;
  output.effective_model_id = effective;
  output.model_version = std::string(descriptor.version);
  output.inference_mode =
      inference_mode.empty() ? std::string(kInferenceModePixelOnly)
                             : std::string(inference_mode);
  output.fallback_reason = std::move(fallback_reason);
  if (descriptor.research_reconstruction_offset) {
    output.base_offset = kResearchBaseOffset;
    output.alternate_offset = kResearchBaseOffset;
  }
  return output;
}

void set_native_model_runtime(NativeModelInfer runtime) {
  std::lock_guard lock(runtime_mutex());
  runtime_slot() = std::move(runtime);
}

void validate_native_model_post_options(const NativeModelPostOptions& post) {
  validate_post_options_impl(post);
}

bool native_model_runtime_available() {
  std::lock_guard lock(runtime_mutex());
  return static_cast<bool>(runtime_slot());
}

NativeModelOutput infer_native_model(const NativeModelRequest& request,
                                     const FloatImage& linear_display_p3_sdr) {
  NativeModelInfer runtime;
  {
    std::lock_guard lock(runtime_mutex());
    runtime = runtime_slot();
  }
  if (!runtime) {
    throw std::runtime_error(
        "embedded native AI model adapter is unavailable; link/register the "
        "model backend before using --ai-model");
  }
  NativeModelRequest normalized;
  normalized.model_id = normalize_native_model_id(request.model_id);
  normalized.capture = request.capture;
  auto output = runtime(normalized, linear_display_p3_sdr);
  // An adapter that forgets the identity fields would otherwise publish an
  // empty model id, which reads downstream as "no model ran".
  if (output.requested_model_id.empty()) output.requested_model_id = normalized.model_id;
  if (output.effective_model_id.empty()) output.effective_model_id = normalized.model_id;
  if (output.model_version.empty()) {
    output.model_version =
        std::string(native_model_descriptor(normalized.model_id).version);
  }
  return output;
}

FloatImage make_native_model_input(const FloatImage& linear_display_p3_sdr,
                                   std::uint32_t long_side) {
  linear_display_p3_sdr.require_consistent("native model source");
  if (linear_display_p3_sdr.channels != 3 ||
      linear_display_p3_sdr.width == 0 || linear_display_p3_sdr.height == 0) {
    throw std::invalid_argument("native model source must be a non-empty RGB image");
  }
  if (long_side < kNativeModelStride || long_side > 8192U) {
    throw std::invalid_argument("native model long side must be in [16, 8192]");
  }
  const auto longest = std::max(linear_display_p3_sdr.width,
                                linear_display_p3_sdr.height);
  const double scale = std::min(
      1.0, static_cast<double>(long_side) / static_cast<double>(longest));
  const auto width = align_stride16(std::max<std::uint32_t>(
      1U, static_cast<std::uint32_t>(std::lround(
          static_cast<double>(linear_display_p3_sdr.width) * scale))));
  const auto height = align_stride16(std::max<std::uint32_t>(
      1U, static_cast<std::uint32_t>(std::lround(
          static_cast<double>(linear_display_p3_sdr.height) * scale))));
  auto tensor = resample_to(linear_display_p3_sdr, width, height);
  validate_model_input(tensor);
  return tensor;
}

FloatImage make_native_model_features(const FloatImage& linear_display_p3_sdr) {
  validate_model_input(linear_display_p3_sdr);
  FloatImage features(linear_display_p3_sdr.width,
                      linear_display_p3_sdr.height, 5);
  constexpr float kLumaR = 0.22897456F;
  constexpr float kLumaG = 0.69173852F;
  constexpr float kLumaB = 0.07928691F;
  for (std::uint32_t y = 0; y < linear_display_p3_sdr.height; ++y) {
    for (std::uint32_t x = 0; x < linear_display_p3_sdr.width; ++x) {
      const auto source =
          (static_cast<std::size_t>(y) * linear_display_p3_sdr.width + x) * 3U;
      const auto target =
          (static_cast<std::size_t>(y) * features.width + x) * 5U;
      const float r = linear_display_p3_sdr.pixels[source];
      const float g = linear_display_p3_sdr.pixels[source + 1];
      const float b = linear_display_p3_sdr.pixels[source + 2];
      const float luma = std::max(0.0F, kLumaR * r + kLumaG * g + kLumaB * b);
      features.pixels[target] = r;
      features.pixels[target + 1] = g;
      features.pixels[target + 2] = b;
      features.pixels[target + 3] =
          std::clamp((std::log2(std::max(luma, 1.0e-6F)) + 12.0F) / 12.0F,
                     0.0F, 1.0F);
      features.pixels[target + 4] = std::max({r, g, b}) >= 0.98F ? 1.0F : 0.0F;
    }
  }
  return features;
}

NativeModelOutput guided_filter_native_model_gain(const FloatImage& model_input,
                                                  NativeModelOutput output) {
  validate_model_input(model_input);
  validate_model_output(model_input, output);

  const auto& predicted = output.signed_log2_gain;
  const auto guide_image = resample_to(model_input, predicted.width,
                                       predicted.height);
  const auto count = predicted.pixels.size();
  std::vector<float> guide(count, 0.0F);
  std::vector<float> global_gain(count, 0.0F);
  std::vector<float> filtered(count, 0.0F);
  float floor = 0.0F;
  for (const float value : predicted.pixels) floor = std::min(floor, value);
  for (std::size_t index = 0; index < count; ++index) {
    const auto pixel = index * 3U;
    guide[index] = p3_luminance(guide_image.pixels[pixel],
                                guide_image.pixels[pixel + 1],
                                guide_image.pixels[pixel + 2]);
    // guided_filter_gain intentionally clamps to [0, global_gain]. Shifting a
    // signed prediction by its minimum lets us reuse that tested edge-aware
    // implementation without discarding negative canonical gains.
    filtered[index] = predicted.pixels[index] - floor;
    global_gain[index] = filtered[index];
  }
  std::vector<float> mean_i(count, 0.0F);
  std::vector<float> mean_p(count, 0.0F);
  std::vector<float> work_one(count, 0.0F);
  std::vector<float> work_two(count, 0.0F);
  std::vector<double> integral(
      (static_cast<std::size_t>(predicted.width) + 1U) *
          (static_cast<std::size_t>(predicted.height) + 1U),
      0.0);
  // This is the native AI path's explicit reuse of the existing guided filter:
  // model cells are edge-aware smoothed against the corresponding SDR base
  // luminance before ISO gain coding or full-resolution reconstruction.
  guided_filter_gain(filtered, global_gain, guide, predicted.width,
                     predicted.height, mean_i, mean_p, work_one, work_two,
                     integral);

  for (std::size_t index = 0; index < count; ++index) {
    output.signed_log2_gain.pixels[index] =
        std::clamp(filtered[index] + floor, -64.0F, 64.0F);
  }
  return output;
}

void apply_native_model_gain_map(GainMapResult& result,
                                 const FloatImage& model_input,
                                 NativeModelOutput output, float strength,
                                 const NativeModelPostOptions& post) {
  result.base_linear.require_consistent("native model result base");
  result.gain_map.require_consistent("native model result gain");
  validate_model_input(model_input);
  validate_model_output(model_input, output);
  validate_post_options_impl(post);
  if (!(std::isfinite(strength) && strength >= 0.0F && strength <= 2.0F)) {
    throw std::invalid_argument("AI gain strength must be in [0, 2]");
  }

  auto& predicted = output.signed_log2_gain;
  const auto guide_base = resample_to(model_input, predicted.width,
                                      predicted.height);
  for (std::size_t index = 0; index < predicted.pixels.size(); ++index) {
    const auto base = index * 3U;
    const float luma = p3_luminance(guide_base.pixels[base],
                                    guide_base.pixels[base + 1],
                                    guide_base.pixels[base + 2]);
    float value = predicted.pixels[index] * strength;
    if (post.expansion_start >= 0.0F) {
      const float start = std::clamp(post.expansion_start, 0.0F, 1.0F);
      value *= smoothstep(start * 0.75F, std::min(1.0F, start * 1.10F),
                          luma);
    }
    if (std::abs(post.highlights_stops) > 1.0e-8F) {
      const float start = post.expansion_start >= 0.0F
                              ? std::clamp(post.expansion_start, 0.0F, 1.0F)
                              : 0.45F;
      value += post.highlights_stops * smoothstep(start, 1.0F, luma);
    }
    value = std::clamp(value, -64.0F, 64.0F);
    if (post.hdr_range_stops >= 0.0F) {
      value = std::clamp(value, -post.hdr_range_stops,
                         post.hdr_range_stops);
    }
    predicted.pixels[index] = value;
  }

  ExternalGainMap external;
  external.gain_map = std::move(predicted);
  external.canonical_log2 = true;
  external.legacy_schema = false;
  float predicted_min_stops = 0.0F;
  float predicted_max_stops = 0.0F;
  for (const float value : external.gain_map.pixels) {
    predicted_min_stops = std::min(predicted_min_stops, value);
    predicted_max_stops = std::max(predicted_max_stops, value);
  }
  predicted_max_stops = std::max(predicted_max_stops, 0.0F);
  external.metadata.gain_min = outward_gain_min(predicted_min_stops);
  external.metadata.gain_max = outward_gain_max(predicted_max_stops);
  external.metadata.gamma = {1, 1};
  // The base offset travels with the prediction. The incumbent model keeps its
  // zero; a research model's reconstruction was trained with 1e-5 subtracted
  // after the gain, so leaving these at zero would render a slightly different
  // curve than the one the model was fitted against.
  external.metadata.base_offset = output.base_offset;
  external.metadata.alternate_offset = output.alternate_offset;
  external.metadata.base_headroom = {0, 1};
  external.metadata.alternate_headroom = external.metadata.gain_max;
  external.max_stops = predicted_max_stops;
  apply_external_gain_map(result, std::move(external), 1.0F, -1.0F);

  // These controls deliberately run after inference. In particular, changing
  // brightness or contrast cannot invalidate/re-run the model tensor.
  adjust_base(result, post);
  if (result.clamp_srgb) {
    parallel_for_rows(result.base_linear.height, [&](const std::uint32_t y) {
      for (std::uint32_t x = 0; x < result.base_linear.width; ++x) {
        const auto index =
            (static_cast<std::size_t>(y) * result.base_linear.width + x) * 3U;
        const auto fitted = compress_linear_p3_to_srgb(
            result.base_linear.pixels[index],
            result.base_linear.pixels[index + 1],
            result.base_linear.pixels[index + 2]);
        result.base_linear.pixels[index] = fitted[0];
        result.base_linear.pixels[index + 1] = fitted[1];
        result.base_linear.pixels[index + 2] = fitted[2];
      }
    });
  }
}

GainMapResult make_native_model_gain_map(
    const FloatImage& source, const GainMapOptions& development,
    const CaptureMetadata& capture, const InputDescription& input,
    std::string_view model_id, std::uint32_t model_long_side, float strength,
    const NativeModelPostOptions& post) {
  auto base_options = development;
  // A model replaces the gain field; the mathematical pass is used only to
  // produce the deterministic SDR base that the model was trained against.
  base_options.gain_strength = 1.0F;
  auto result = make_gain_map(source, base_options, capture, input);
  auto model_input = make_native_model_input(result.base_linear, model_long_side);
  NativeModelRequest request;
  request.model_id = normalize_native_model_id(model_id);
  request.capture = capture_parameters_from_metadata(capture);
  auto output = infer_native_model(request, model_input);
  apply_native_model_gain_map(result, model_input, std::move(output), strength,
                              post);
  return result;
}

}  // namespace hyperdr
