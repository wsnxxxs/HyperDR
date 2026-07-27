#pragma once

// The full-resolution pass that writes the SDR base image.
//
// It runs once, after the low-resolution gain grid is final, and is where the
// two renditions are kept consistent: chroma is processed once and shared, so
// the SDR base and the HDR reconstruction differ in luminance only.

#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/look/tone_curve.hpp"

#include <array>
#include <cstdint>
#include <vector>

namespace hyperdr {

// Shared chroma for one pixel, expressed in the SDR base's range. The returned
// triple is clamped into [0, 1] and rescaled to `sdr_y`, so encoding it cannot
// clip an individual channel and shift the hue that the gain map then
// magnifies.
[[nodiscard]] std::array<float, 3> render_common_chroma(
    float r, float g, float b, float source_y, float sdr_y, float hdr_y,
    float peak, const LookOptions& look);

// Fills `result.base_linear` and the measured half of `result.stats`.
// `result.gain_map` must already hold the encoded grid.
void render_full_resolution(const FloatImage& source, float exposure,
                            const std::vector<float>& local_grid,
                            std::uint32_t gain_width, std::uint32_t gain_height,
                            float stored_gain_max, float stored_gamma,
                            float target_peak, const LookOptions& look,
                            GainMapResult& result);

}  // namespace hyperdr
