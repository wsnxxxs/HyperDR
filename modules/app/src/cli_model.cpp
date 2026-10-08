#include "cli_commands.hpp"

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

namespace hyperdr::app::detail {

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

int model_gain_command(int argc, char** argv) {
  if (argc < 3) throw std::invalid_argument("model-gain requires one input image");
  ConvertOptions options;
  options.input = path_from_utf8(argv[2]);
  parse_settings(argc, argv, 3, options);
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
  options.raw.ignore_embedded_gain_map = false;
  options.raw.default_gamut = options.default_gamut;
  validate_gain_map_options(options.gain);

  auto decoded = decode_cached_image(options.input, options, options.raw);
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
      .begin_object("source_color")
      .member("name", decoded.source_color.name)
      .member("primaries", decoded.source_color.primaries)
      .member("transfer", decoded.source_color.transfer)
      .member("source", decoded.source_color.source)
      .end_object()
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
      output = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--report") {
      report = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--long-side") {
      long_side = integer<std::uint32_t>(next_value(i, argc, argv, arg),
                                         "model long side");
    } else if (arg == "--half-size") {
      options.raw.half_size = true;
    } else if (arg == "--raw-bad-pixels") {
      options.raw.bad_pixel_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-dark-frame") {
      options.raw.dark_frame = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-linearization-lut") {
      options.raw.linearization_lut = path_from_utf8(next_value(i, argc, argv, arg));
    } else if (arg == "--raw-lens-shading") {
      options.raw.lens_shading_map = path_from_utf8(next_value(i, argc, argv, arg));
    } else {
      throw std::invalid_argument("unknown model-input option: " + std::string(arg));
    }
  }
  if (output.empty() || report.empty()) {
    throw std::invalid_argument("model-input requires --output and --report");
  }
  apply_output_color_options(options);
  const std::filesystem::path input = path_from_utf8(argv[2]);
  if (same_path(input, output) || same_path(input, report) || same_path(output, report)) {
    throw std::invalid_argument("model-input source, pixels and report must be distinct");
  }
  validate_gain_map_options(options.gain);
  options.raw.ignore_embedded_gain_map = false;
  options.raw.default_gamut = options.default_gamut;
  auto decoded = decode_image(input, options.raw);
  if (decoded.describe_input().domain == InputDomain::kDisplayReferredHdr ||
      decoded.describe_input().domain == InputDomain::kDualRendition) {
    throw std::invalid_argument(
        "model-input requires SDR or RAW input; HDR and dual-rendition photos already contain authored HDR");
  }
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

}  // namespace hyperdr::app::detail
