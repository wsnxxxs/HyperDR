#pragma once

// In-memory bridge between the bundled native gain predictor and HyperDR's
// ordinary gain-map renderer. The model runtime is deliberately a small
// callback: the core owns colour conversion, resizing, ISO
// coding and rendering, while the embedded-model adapter owns the concrete
// inference backend and bundled weights.

#include "hyperdr/gainmap/types.hpp"

#include <cstdint>
#include <filesystem>
#include <functional>
#include <string_view>

namespace hyperdr {

inline constexpr std::uint32_t kNativeModelStride = 16U;
inline constexpr std::uint32_t kDefaultNativeModelLongSide = 1024U;
inline constexpr std::string_view kEmbeddedNativeModel = "embedded";
inline constexpr std::string_view kEmbeddedNativeModelId =
    "hyperdr.direct-fixed-incumbent/v3-production";

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

// A runtime adapter returns one signed canonical log2 gain sample per model
// cell. The input is HWC linear Display-P3 SDR, and its dimensions are aligned
// to kNativeModelStride. The output dimensions must be exactly input/16. The
// adapter may retain no reference to the input after returning.
struct NativeModelOutput {
  FloatImage signed_log2_gain;
};

// `model_artifact` is normally the CLI's "embedded" sentinel. It remains in
// the seam so a development adapter can select a test model without changing
// the application/rendering API; the shipping adapter ignores it.
using NativeModelInfer = std::function<NativeModelOutput(
    const std::filesystem::path& model_artifact,
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
// CLI/application.
[[nodiscard]] NativeModelOutput infer_native_model(
    const std::filesystem::path& model_artifact,
    const FloatImage& linear_display_p3_sdr);

// Converts an SDR base into the model tensor geometry. Both dimensions are
// ceil-aligned to stride 16; reductions use the shared area-then-bilinear
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
void apply_native_model_gain_map(
    GainMapResult& result, const FloatImage& model_input,
    NativeModelOutput output, float strength = 1.0F,
    const NativeModelPostOptions& post = {});

// Convenience wrapper for callers that have a source but not a pre-rendered
// base. It creates the mathematical SDR base with gain strength pinned to one,
// builds the model thumbnail, invokes the registered runtime, and applies the
// prediction in memory.
[[nodiscard]] GainMapResult make_native_model_gain_map(
    const FloatImage& source, const GainMapOptions& development,
    const CaptureMetadata& capture = {},
    const InputDescription& input = {},
    const std::filesystem::path& model_artifact = {},
    std::uint32_t model_long_side = kDefaultNativeModelLongSide,
    float strength = 1.0F,
    const NativeModelPostOptions& post = {});

}  // namespace hyperdr
