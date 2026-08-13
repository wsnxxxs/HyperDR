#pragma once

// Reading and applying the raw gain-grid interchange produced by an external
// model such as HyperDR_Model. The sidecar is mandatory: raw float grids do
// not carry their dimensions or gain range by themselves.

#include "hyperdr/gainmap/types.hpp"

#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace hyperdr {

// Identity, geometry and development state frozen when a model input is
// produced.  Generic external gain grids (for example Phase A labels) do not
// have to carry this block, but model-generated grids do.  The application
// validates it against the current source and decode before rendering.
struct ExternalDevelopmentRecipe {
  float exposure_ev{};
  float headroom_stops{};
  float contrast{};
  float vibrance{};
  float pop{};
  float toe_end{};
  float toe_output_ratio{};
  float shoulder_start{};
  float positive_exposure_limit_ev{};
  float diffuse_gain_floor{};
};

struct ExternalGainBinding {
  std::string source_sha256;
  std::string highlight_recovery;
  std::uint32_t orientation{1};
  std::uint32_t sensor_width{};
  std::uint32_t sensor_height{};
  std::uint32_t requested_crop_width{};
  std::uint32_t requested_crop_height{};
  std::uint32_t requested_crop_left{};
  std::uint32_t requested_crop_top{};
  // The actual LibRaw/raster dimensions used to develop the model input,
  // before the final tensor resample.  For a RAW half-size decode these are
  // deliberately not confused with requested_crop_*.
  std::uint32_t delivered_crop_width{};
  std::uint32_t delivered_crop_height{};
  std::uint32_t delivered_crop_left{};
  std::uint32_t delivered_crop_top{};
  bool raw_half_size{false};
  std::uint32_t model_width{};
  std::uint32_t model_height{};
  std::uint32_t gain_width{};
  std::uint32_t gain_height{};
  std::string resize_convention;
  std::string model_version;
  std::string checkpoint_sha256;
  ExternalDevelopmentRecipe recipe;
};

struct ExternalGainMap {
  FloatImage gain_map;
  float max_stops{};
  // v2 stores signed canonical log2 gains and the exact ISO metadata.  v1
  // stores normalized [0,1] samples and is accepted only in explicit legacy
  // compatibility mode by the application boundary.
  GainMapMetadata metadata{};
  bool canonical_log2{false};
  bool legacy_schema{false};
  std::optional<ExternalGainBinding> binding;
};

// Reads a little-endian HW float32 grid and validates the matching JSON
// sidecar before any pixels enter the encoder.
[[nodiscard]] ExternalGainMap read_external_gain_map(
    const std::filesystem::path& gain_path,
    const std::filesystem::path& report_path,
    bool allow_legacy_external_gain = false);

// Builds the normal rendition first and then replaces only its gain grid.  The
// mathematical path therefore remains the single owner of the SDR base,
// exposure, tone curve, gamut mapping, contrast and vibrance.
//
// `input` picks which of those renderers runs, exactly as it does for
// make_gain_map. A model grid trained on scene-referred development is only
// meaningful over a scene-referred base, so a caller that supplies a grid for a
// display-referred input gets that input's own base underneath it rather than a
// re-developed one.
[[nodiscard]] GainMapResult make_external_gain_map(
    const FloatImage& source, ExternalGainMap external,
    const GainMapOptions& options = {},
    const CaptureMetadata& capture = {},
    const InputDescription& input = {});

// Replaces an existing result's gain map and metadata. Kept for callers that
// intentionally prepared their own base before applying an external grid.
void apply_external_gain_map(GainMapResult& result, ExternalGainMap external,
                             float strength = 1.0F,
                             float output_headroom_limit_stops = -1.0F);

}  // namespace hyperdr
