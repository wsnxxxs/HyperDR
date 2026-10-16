#include "engine_internal.hpp"
#include "preview_binary.hpp"

#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/preview.hpp"
#include "hyperdr/app/schema.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/version.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/image/dcp_profile.hpp"
#include "hyperdr/image/resample.hpp"

#include <bit>
#include <cmath>
#include <cstring>
#include <iostream>
#include <utility>

namespace hyperdr {

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

std::vector<std::uint8_t> render_model_gain(ConvertOptions options,
    const std::function<const DecodedImage&(const ConvertOptions&)>& decode) {
  apply_output_color_options(options);
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
    return native_model_gain_packet(prediction, "undeclared");
  }

  if (options.preview_max_edge == 0) options.preview_max_edge = 2048;
  options.decode_intent = DecodeIntent::Preview;
  options.raw.preview_max_edge = options.preview_max_edge;
  options.raw.half_size = is_raw_extension(lower_extension(options.input));
  options.raw.ignore_embedded_gain_map = false;
  options.raw.default_gamut = options.default_gamut;
  validate_gain_map_options(options.gain);

  const auto& decoded = decode(options);
  const auto input = decoded.describe_input();
  if (input.domain == InputDomain::kDisplayReferredHdr ||
      input.domain == InputDomain::kDualRendition) {
    throw std::invalid_argument(
        "--ai-model requires SDR or RAW input; HDR and dual-rendition photos already contain authored HDR");
  }
  auto result = render_native_model_base(decoded, options.clamp_srgb);
  auto model_input = make_native_model_input(result.base_linear);
  auto prediction = infer_native_model(native_model_request(options, decoded.metadata),
                                       model_input);
  return native_model_gain_packet(prediction, input_domain_name(input.domain));
}

}  // namespace hyperdr
