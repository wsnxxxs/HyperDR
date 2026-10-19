#pragma once

#include "hyperdr/app/settings.hpp"
#include <algorithm>
#include <cstdint>

namespace hyperdr {
// Peak footprint of each successive stage, not the sum of all stages. HEIC
// verification decodes tile by tile through our HEIF reader and VideoToolbox:
// it holds the compressed file and a few tiles, never a canvas-sized raster
// (measured 41-79 MB for a 185 MP story canvas).
struct ExportMemoryEstimate {
  std::uint64_t decode{}, render{}, composite{}, packaging{}, encode{}, verify{};
  [[nodiscard]] std::uint64_t peak() const noexcept {
    return std::max({decode, render, composite, packaging, encode, verify});
  }
};
[[nodiscard]] ExportMemoryEstimate estimate_export_memory(
    std::uint32_t photo_width, std::uint32_t photo_height,
    std::uint32_t canvas_width, std::uint32_t canvas_height,
    OutputEncoding encoding, int depth, bool raw,
    std::uint32_t sensor_width = 0, std::uint32_t sensor_height = 0,
    unsigned tile_workers = 0, bool retained_renditions = false,
    std::uint64_t retained_resource_bytes = 0,
    // Pixels of the external gain grid the parser will allocate (0 = none).
    std::uint64_t external_gain_pixels = 0,
    // The only reason for `retained_renditions` is an imported dual rendition
    // (an authored SDR base with a gain map): no LUT, model or external grid.
    // Such a pair costs less than the 80 B/px those add.
    bool authored_pair_only = false);
[[nodiscard]] std::uint64_t export_resource_bytes(const ConvertOptions& options);
// Zero means that the host could not report its physical memory. A configured
// limit still applies in that case. The system reserve matches RAW's 512 MiB.
[[nodiscard]] std::uint64_t export_memory_budget(std::uint64_t configured,
                                                std::uint64_t physical) noexcept;
}  // namespace hyperdr
