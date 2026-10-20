#pragma once

// Running one conversion, and running many sequentially.

#include "hyperdr/app/settings.hpp"
#include "hyperdr/gainmap/external.hpp"

#include <vector>
#include <string_view>
#include "hyperdr/foundation/progress.hpp"

namespace hyperdr {

// Reads a UTF-8 frame document; relative overlays resolve beside the document.
[[nodiscard]] FrameSpec read_frame_spec(const std::filesystem::path& path);

// Checks export-only frame resources before decoding or creating output paths.
// Layout and canonical request computations intentionally do not perform I/O.
void validate_frame_resources(const FrameSpec& frame);

// Enforces the non-degradable resolution contract before any gain-map work or
// output allocation begins. Public so the invariant has a fixture-free test.
void require_decode_resolution(const ConvertOptions& options,
                               const DecodeInfo& decode);

// Renders one decoded image, choosing the renderer from the domain the decoder
// recorded.
//
// This replaces an earlier helper that decided the same question from the file
// extension, which classified an Ultra HDR JPEG that had fallen back to its SDR
// primary as HDR and could not tell a PQ HEIC from an sRGB one at all.
[[nodiscard]] GainMapResult render_decoded_image(const DecodedImage& image,
                                                 const GainMapOptions& options,
                                                 const std::filesystem::path& analysis_cache = {},
                                                 std::uint64_t cache_budget_bytes = 0);

// Produces the exact SDR base consumed by the native model and retained by the
// final render. Finished SDR is passed through sample-for-sample; scene-linear
// RAW keeps automatic exposure but uses a fixed neutral development.
[[nodiscard]] GainMapResult render_native_model_base(
    const DecodedImage& image, bool clamp_srgb = false,
    const PhotographicAnalysis* analysis = nullptr);

// The development options render_native_model_base uses; model-input reports
// record exactly these, so a replay cannot differ from what the model saw.
[[nodiscard]] GainMapOptions native_model_development_options(
    InputDomain domain, bool clamp_srgb = false);

// Stable provenance name used by model-input reports and conversion reports.
[[nodiscard]] const char* native_model_development_kind(
    InputDomain domain) noexcept;

// Validates a model sidecar against the current file/decode and returns the
// frozen photographic recipe to replay. Public for fixture-free stale-grid
// regression tests.
[[nodiscard]] GainMapOptions replay_external_development(
    const ExternalGainMap& external, const std::filesystem::path& input,
    const DecodedImage& image, const ConvertOptions& options);

// Decodes, renders, encodes, verifies and publishes one file. Never throws for a
// per-file failure: the reason lands in the result so a batch can continue.
[[nodiscard]] FileResult convert_file(const std::filesystem::path& input,
                                      const ConvertOptions& options,
                                      const std::string& fingerprint, ProgressSink* sink = nullptr,
                                      std::string_view hevc_override = {});

// Converts everything `discover_input_files` finds. Returns a process exit code:
// 0 when every file succeeded or was skipped.
[[nodiscard]] int run_conversion(const ConvertOptions& options, ProgressSink* sink = nullptr,
                                  std::string* report = nullptr, std::string_view hevc_override = {});

}  // namespace hyperdr
