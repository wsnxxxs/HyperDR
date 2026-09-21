#pragma once

// Everything one `convert` run was asked to do, and what it reported back.

#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/look/color_lut.hpp"

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace hyperdr {

enum class DecodeIntent {
  Export,
  Preview,
};

struct ConvertOptions {
  std::filesystem::path input;
  std::filesystem::path output_directory;
  bool recursive{false};
  bool overwrite{false};
  bool skip_existing{false};
  bool verify_output{true};
  // Zero keeps the original resolution. Non-zero bounds the decoded image
  // before the look and gain-map pipeline.
  std::uint32_t preview_max_edge{0};
  // Explicit workflow intent. Code must not infer this later from a size,
  // cache directory, quality setting, or other side-effect signal.
  DecodeIntent decode_intent{DecodeIntent::Export};
  int quality{90};
  // 8-bit matches what the iPhone camera itself writes for gain-map HEICs and
  // has the broadest decoder support; 10 selects HEVC Main10 (which requires
  // the multibit x265 runtime).
  int depth{8};
  OutputEncoding encoding{OutputEncoding::Adaptive};
  ColorLutOptions color_lut;
  ColorGamut default_gamut{ColorGamut::kSrgb};
  bool clamp_srgb{false};
  RawDecodeOptions raw;
  GainMapOptions gain;
  std::filesystem::path report_path;
  // Optional raw gain-grid output from an external model. The JSON sidecar is
  // required because the raw file carries neither dimensions nor scale.
  std::filesystem::path external_gain_path;
  std::filesystem::path external_gain_report;
  // Explicitly re-enable the frozen v1 normalized sidecar contract.
  bool allow_legacy_external_gain{false};
  // Enables one of the embedded in-process AI models. The runtime receives the
  // existing linear Display-P3 SDR thumbnail directly; no model-input/gain
  // sidecars are written. The field keeps its original name and type so existing
  // callers and the settings vocabulary do not change, but its value is now a
  // model id from the fixed table rather than a path: the shipping adapter owns
  // the assets and never opens a caller-named file. The legacy "embedded"
  // sentinel still selects the incumbent model, and an empty value means no
  // model at all.
  std::filesystem::path ai_model_path;
  NativeModelPostOptions ai_post;
  // `model-gain` only: a pre-developed HWC linear Display-P3 float32 tensor to
  // run the model on instead of decoding an image.
  //
  // The conversion check this exists for has to compare PyTorch and ncnn on the
  // *same* tensor. Running both against the same file would fold the decode and
  // resample differences into the same number as the conversion error, and the
  // two would then be indistinguishable. It is not a way to bypass the decode
  // path in normal use: the dimensions are required, so a caller has to say what
  // it is feeding rather than have it guessed.
  std::filesystem::path model_input_tensor;
  std::uint32_t model_input_tensor_width{};
  std::uint32_t model_input_tensor_height{};
  // `model-gain` only: the capture settings to send with `model_input_tensor`,
  // as a JSON object keyed by the six ordinary names. An absent key and an
  // explicit null both mean "the tag was not recorded", which is the case the
  // level estimator's fallback rule turns on and the one a photograph cannot be
  // asked for on demand. Without this file the tensor path has no capture at
  // all, so a model that needs one falls back exactly as it would for an image
  // whose tags were missing.
  std::filesystem::path model_capture_path;
  // Optional directory for cached decoded buffers. Interactive preview reruns
  // change only post-decode look controls, so caching the decode turns each
  // slider move from a full RAW read into a file copy.
  std::filesystem::path decode_cache_directory;
  // Optional digest already computed by the panel while ingesting the image.
  // A standalone CLI run leaves it empty and the cache computes the digest.
  std::string decode_cache_source_sha256;
  std::uint64_t decode_cache_budget_bytes{2ULL * 1024ULL * 1024ULL * 1024ULL};
};

// Rejects combinations no encoder can honour, before any file is opened.
void validate_convert_options(const ConvertOptions& options);

// Whether this run selected a native model at all.
[[nodiscard]] bool uses_native_model(const ConvertOptions& options);

// The canonical model id this run selected, or an empty string when it selected
// none. An unknown id is an error here rather than a silent substitution of the
// incumbent: a typo that quietly rendered with another model would be worse than
// a failed run, because the report would look successful.
[[nodiscard]] std::string selected_native_model_id(const ConvertOptions& options);

// The model request for one decoded image: the selected id, plus the capture
// settings the decoder actually read.
//
// Four sites infer a model -- the cached and uncached preview paths, model-gain
// and the batch converter -- and all of them have to send the same thing.
// Building the request in one place is what keeps model 2 from being fed a
// complete capture on the panel's probe and an empty one on export, which would
// look like the model changing its mind about the same photograph.
//
// `metadata` is `PhotoMetadata`, not `CaptureMetadata`, because only the former
// preserves whether a tag was present: an exposure bias of 0 EV is a real value
// and the level estimator's fallback rule turns on that distinction.
[[nodiscard]] NativeModelRequest native_model_request(const ConvertOptions& options,
                                                      const PhotoMetadata& metadata);

// Rejects a rendered peak that the selected transfer function cannot encode.
// This second boundary matters for external gain maps: their authoritative
// metadata is not known when ConvertOptions is first validated.
void validate_encoding_headroom(HdrEncoding encoding, float headroom_stops);

struct FileResult {
  std::filesystem::path input;
  std::filesystem::path output;
  bool success{false};
  bool skipped{false};
  bool self_verified{false};
  std::string message;
  std::uint32_t sensor_width{};
  std::uint32_t sensor_height{};
  std::uint32_t target_width{};
  std::uint32_t target_height{};
  std::uint32_t decoded_width{};
  std::uint32_t decoded_height{};
  // Unambiguous crop vocabulary for model bindings. target_*/decoded_* remain
  // as compatibility aliases carried forward from schema 7.
  std::uint32_t requested_crop_width{};
  std::uint32_t requested_crop_height{};
  std::uint32_t delivered_crop_width{};
  std::uint32_t delivered_crop_height{};
  // See DecodeInfo: target_dimensions_applied is the only one of these a
  // consumer may branch on, and the reasons are presentation only.
  bool target_dimensions_applied{true};
  bool default_crop_present{false};
  bool decode_degraded{false};
  std::string raw_white_balance;
  std::string raw_color_matrix;
  std::string raw_profile_name, raw_profile_sha256, raw_profile_camera, raw_profile_tone;
  std::string raw_lens_profile, raw_lens_correction;
  float raw_profile_baseline_ev{};
  std::vector<std::string> decode_degradation_reasons;
  // Which renderer ran, and the headroom it was told the input carried. These
  // are the two facts that decide what every other number in this record means:
  // `exposure_ev` is an automatic scene decision for a scene-referred input and
  // a pure creative offset for the other two, and `headroom_stops` is content
  // dependent for the first and bounded by `input_headroom` for the third.
  // Unknown means the file was skipped or failed before a decoder could state
  // which renderer it would have used. It is not a rendering domain.
  InputDomain input_domain{InputDomain::kUnknown};
  // Native-model input/base preparation, or "none" for the manual/external
  // paths and failures before model preparation.
  std::string model_development{"none"};
  // What the user selected, and what actually produced the gain. These differ
  // whenever model 2 answered with model 1's prediction because the capture
  // settings were incomplete, which is exactly the case a single `model_id`
  // field used to hide.
  std::string model_requested_id{"none"};
  std::string model_id{"none"};
  std::string model_version{"none"};
  std::string model_inference_mode{"none"};
  // Empty when the effective model is the requested one.
  std::string model_fallback_reason;
  // 1.0 is a schema-safe sentinel when input_domain is unknown; consumers must
  // read input_domain before interpreting this value.
  float input_headroom{1.0F};
  std::uint32_t width{};
  std::uint32_t height{};
  double exposure_ev{};
  double headroom_stops{};
  double gain_min{};
  double gain_max{};
  // API3 measures gain against the final JPEG; only header statistics are read
  // back. The renderer's pre-compression gain distribution does not describe it.
  bool codec_gain{false};
  double decode_ms{};
  double process_ms{};
  double encode_ms{};
  double codec_ms{};
  double verify_ms{};
  double write_ms{};
  RenderStats stats;
};

}  // namespace hyperdr
