#pragma once

// In-memory bridge between the bundled native gain predictor and HyperDR's
// ordinary gain-map renderer. The model runtime is deliberately a small
// callback: the core owns colour conversion, resizing, ISO
// coding and rendering, while the embedded-model adapter owns the concrete
// inference backend and bundled weights.

#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/gainmap/types.hpp"

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace hyperdr {

inline constexpr std::uint32_t kNativeModelStride = 16U;
inline constexpr std::uint32_t kDefaultNativeModelLongSide = 1024U;

// The CLI sentinel selects the default CNN.
inline constexpr std::string_view kEmbeddedNativeModel = "embedded";
inline constexpr std::string_view kResearchCnnModelId = "research-cnn-v1";
inline constexpr std::string_view kResearchExifModelId = "research-exif-v1";

// How a prediction was produced, reported alongside the model that produced it.
// `kPixelOnlyFallback` is not an error: it is model 2 answering with model 1's
// answer because the capture settings it needs were not there.
inline constexpr std::string_view kInferenceModePixelOnly = "pixel_only";
inline constexpr std::string_view kInferenceModeExifAssisted = "exif_assisted";
inline constexpr std::string_view kInferenceModeFallback = "pixel_only_fallback";
//: A model was selected but its gain was not needed: an SDR output assembles no
//: gain map, so the run reports the model it would have used rather than an empty
//: field that reads as "no model".
inline constexpr std::string_view kInferenceModeNotRun = "not_run";

// One selectable model.  The table is fixed at compile time on purpose: the
// runtime never opens a user-named model file, so this is the whole of what can
// be selected, and a build that is missing an asset fails at startup rather than
// at the first request.
struct NativeModelDescriptor {
  std::string_view id;
  // Chinese name the panel shows; the browser also has an i18n key so the
  // English string does not have to be duplicated here.
  std::string_view display_name;
  std::string_view display_key;
  std::string_view version;
  // Empty when the model never answers with another model's result.
  std::string_view fallback_id;
  // Whether the capture settings are an input at all.
  bool requires_capture;
  // Whether the reconstruction offsets differ from the incumbent's zero.
  bool research_reconstruction_offset;
};

// The two shipped options, in the order the panel lists them.
[[nodiscard]] const std::vector<NativeModelDescriptor>& native_model_table();

[[nodiscard]] bool native_model_id_known(std::string_view requested);

// An empty request or the embedded sentinel selects CNN. Unknown IDs are rejected.
[[nodiscard]] std::string normalize_native_model_id(std::string_view requested);

// The descriptor for a canonical id. Throws for an unknown id.
[[nodiscard]] const NativeModelDescriptor& native_model_descriptor(
    std::string_view canonical_id);

// Machine-readable capability list for ``model-list --json``. The panel reads
// this once per executable version instead of hard-coding a list that the
// binary would then have to agree with.
[[nodiscard]] std::string native_model_list_json();

// Controls applied after the model has produced a gain field.  The values are
// intentionally independent of GainMapOptions: these knobs are post-model
// operations and must not change the tensor that was inferred.
struct NativeModelPostOptions {
  // EV applied to the SDR base. Zero is the identity.
  float brightness_ev{0.0F};
  // Multiplicative slope around diffuse white (0.18). One is the identity.
  float contrast{1.0F};
  // EV adjustment weighted towards shadows. Zero is the identity.
  float shadows_ev{0.0F};
  // Gain-stop adjustment weighted towards highlights. Zero is the identity.
  float highlights_stops{0.0F};
  // Maximum output gain range in stops. A negative value leaves the model's
  // range untouched; non-negative values cap both samples and ISO metadata.
  float hdr_range_stops{-1.0F};
  // Linear SDR base luminance where expansion starts. Negative disables this
  // gate; otherwise the gain is smoothly suppressed below this level.
  float expansion_start{-1.0F};
};

// What the adapter is asked for.  `model_id` is always canonical by the time an
// adapter sees it; `capture` carries presence, not defaulted numbers.
struct NativeModelRequest {
  std::string model_id;
  // Only read by a model whose descriptor sets `requires_capture`. A model that
  // does not need the capture settings must not change its answer when they are
  // present, so passing them is not an instruction to use them.
  CaptureParameters capture;
};

// A runtime adapter returns one signed canonical log2 gain sample per model
// cell. The input is HWC linear Display-P3 SDR, and its dimensions are aligned
// to kNativeModelStride. The output dimensions must be exactly input/16. The
// adapter may retain no reference to the input after returning.
struct NativeModelOutput {
  FloatImage signed_log2_gain;
  // What was asked for, what actually ran, and under which convention. A caller
  // that only reports the requested id cannot tell a fallback from a result.
  std::string requested_model_id;
  std::string effective_model_id;
  std::string model_version;
  std::string inference_mode{kInferenceModePixelOnly};
  // Empty when `effective_model_id` is what was requested. Otherwise it names
  // the condition, not merely the missing field, so a report can group them.
  std::string fallback_reason;
  // ISO 21496-1 offsets the reconstruction adds to the linear SDR base.
  Rational base_offset{0, 1};
  Rational alternate_offset{0, 1};
};

// `request.model_id` selects the asset and the combination; the shipping
// adapter owns both and never opens a caller-supplied file.
using NativeModelInfer = std::function<NativeModelOutput(
    const NativeModelRequest& request,
    const FloatImage& linear_display_p3_sdr)>;

// Validates post-model controls without requiring an image or a runtime.
void validate_native_model_post_options(const NativeModelPostOptions& post);

// Register the process-local embedded-model adapter during startup. The core
// does not prescribe whether the adapter uses ncnn, DirectML, or another
// backend, and the shipping adapter owns the bundled model assets. Passing an
// empty callback restores the unavailable state. The callback is copied and
// can be replaced between requests; callers must not replace it while an
// inference is active.
void set_native_model_runtime(NativeModelInfer runtime);

[[nodiscard]] bool native_model_runtime_available();

// Calls the registered adapter, or throws a clear error when the embedded
// adapter was not linked. This is the only model-runtime call made by the
// CLI/application. The request is normalized here, once, so every caller path
// -- probe, preview, convert, batch -- reaches the adapter with the same id.
[[nodiscard]] NativeModelOutput infer_native_model(
    const NativeModelRequest& request, const FloatImage& linear_display_p3_sdr);

// Converts an SDR base into the model tensor geometry. Both dimensions are
// ceil-aligned to stride 16; reductions use the shared uniform-area
// resampler so the model sees the same linear Display-P3 thumbnail as the
// preview path rather than an 8-bit intermediate.
[[nodiscard]] FloatImage make_native_model_input(
    const FloatImage& linear_display_p3_sdr,
    std::uint32_t long_side = kDefaultNativeModelLongSide);

// Builds the five-channel BCHW feature contract used by the bundled ncnn
// graph, in HWC storage so it remains a normal FloatImage at the module
// boundary: RGB, normalized log2 luminance, and a clipping indicator. Runtime
// adapters can use this helper instead of reimplementing model preprocessing.
[[nodiscard]] FloatImage make_native_model_features(
    const FloatImage& linear_display_p3_sdr);

// Runs the shared edge-aware guided filter over a raw model prediction while
// retaining its stride-16 dimensions. This is useful for packet/debug callers
// that need the model grid itself rather than the container-lifted grid in a
// GainMapResult.
[[nodiscard]] NativeModelOutput guided_filter_native_model_gain(
    const FloatImage& model_input, NativeModelOutput output);

// Validates the callback output and applies it to an existing mathematical
// result. Gain-domain controls are applied once to the raw signed-stop grid,
// which is then passed through the existing external gain-map encoder and
// lifted once. The compatibility guided-filter helper above is not part of
// this default path. The existing result base is retained and is
// rendered/reconstructed by the normal downstream pipeline.
//
// The reconstruction offsets travel with the prediction rather than being
// assumed: the incumbent model leaves them at zero, while the research models
// carry the 1e-5 the research reconstruction adds to the base before applying
// the gain. Setting them here is not enough on its own -- they have to survive
// into the encoded metadata and the actual reconstruction, which is what
// `apply_external_gain_map` is being handed them for.
void apply_native_model_gain_map(
    GainMapResult& result, const FloatImage& model_input,
    NativeModelOutput output, float strength = 1.0F,
    const NativeModelPostOptions& post = {});

// The capture settings a model request carries, adapter-independent: the
// renderer's optional floats are widened here and a value that is absent stays
// absent. `CaptureMetadata` cannot express "the tag was there and held zero",
// which is exactly the case the level estimator's presence rule turns on, so a
// caller that has the parsed metadata should pass its `capture` member instead.
[[nodiscard]] CaptureParameters capture_parameters_from_metadata(
    const CaptureMetadata& capture);

// Builds a prediction's identity from the fixed table.
//
// An adapter that returned its own strings could disagree with the table about
// a model's version or its reconstruction convention, and the disagreement
// would only show up as a slightly wrong curve. Deriving the conventions from
// the model that actually answered -- `effective_id`, not `requested_id` --
// keeps a fallback honest: the offsets follow whoever produced the numbers.
[[nodiscard]] NativeModelOutput make_native_model_output(
    std::string_view requested_id, std::string_view effective_id,
    std::string_view inference_mode, std::string fallback_reason,
    FloatImage signed_log2_gain);

// Convenience wrapper for callers that have a source but not a pre-rendered
// base. It creates the mathematical SDR base with gain strength pinned to one,
// builds the model thumbnail, invokes the registered runtime, and applies the
// prediction in memory. `model_id` accepts the same spellings as the CLI flag.
[[nodiscard]] GainMapResult make_native_model_gain_map(
    const FloatImage& source, const GainMapOptions& development,
    const CaptureMetadata& capture = {},
    const InputDescription& input = {},
    std::string_view model_id = {},
    std::uint32_t model_long_side = kDefaultNativeModelLongSide,
    float strength = 1.0F,
    const NativeModelPostOptions& post = {});

// The capture settings a model request carries, adapter-independent: the
// renderer's optional floats are widened here and a value that is absent stays
// absent. `renderer_capture` cannot express "the tag was there and held zero",
// which is exactly the case the level estimator's presence rule turns on, so the
// caller that has the metadata should pass it through this instead.
[[nodiscard]] CaptureParameters capture_parameters_from_metadata(
    const CaptureMetadata& capture);

// Builds a prediction's identity from the fixed table.
//
// An adapter that returned its own strings could disagree with the table about
// a model's version or its reconstruction convention, and the disagreement
// would only show up as a slightly wrong curve. Deriving the conventions from
// the model that actually answered -- `effective_id`, not `requested_id` --
// keeps a fallback honest: the offsets follow whoever produced the numbers.
[[nodiscard]] NativeModelOutput make_native_model_output(
    std::string_view requested_id, std::string_view effective_id,
    std::string_view inference_mode, std::string fallback_reason,
    FloatImage signed_log2_gain);

}  // namespace hyperdr
