#pragma once

// Reading and applying the raw gain-grid interchange produced by an external
// model such as HyperDR_Model. The sidecar is mandatory: raw float grids do
// not carry their dimensions or gain range by themselves.

#include "hyperdr/gainmap/types.hpp"

#include <filesystem>

namespace hyperdr {

struct ExternalGainMap {
  FloatImage gain_map;
  float max_stops{};
  // v2 stores signed canonical log2 gains and the exact ISO metadata.  v1
  // stores normalized [0,1] samples and is accepted only in explicit legacy
  // compatibility mode by the application boundary.
  GainMapMetadata metadata{};
  bool canonical_log2{false};
  bool legacy_schema{false};
};

// Reads a little-endian HW float32 grid and validates the matching JSON
// sidecar before any pixels enter the encoder.
[[nodiscard]] ExternalGainMap read_external_gain_map(
    const std::filesystem::path& gain_path,
    const std::filesystem::path& report_path,
    bool allow_legacy_external_gain = false);

// Builds a pure external-model rendition. The SDR base is the decoded source
// clamped to its legal range; exposure, tone curve, local contrast, vibrance
// and every generated-gain parameter are deliberately bypassed.
[[nodiscard]] GainMapResult make_external_gain_map(
    const FloatImage& source, ExternalGainMap external,
    float strength = 1.0F);

// Replaces an existing result's gain map and metadata. Kept for callers that
// intentionally prepared their own base before applying an external grid.
void apply_external_gain_map(GainMapResult& result, ExternalGainMap external);

}  // namespace hyperdr
