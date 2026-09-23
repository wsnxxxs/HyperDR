#pragma once

// How a gain value becomes a stored code, and back.
//
// ISO 21496-1 decodes a stored code with pow(code, 1 / gamma). Keeping both
// directions and the gamma search here makes the convention directly testable,
// and means the encoder and the verifier cannot disagree about it.

#include "hyperdr/foundation/rational.hpp"

#include <cstdint>
#include <vector>

namespace hyperdr {

struct RenderStats;
struct FloatImage;

struct QuantizedGainGrid {
  std::vector<float> codes;
  float stored_gain_max{0.0F};
  float stored_gamma{1.0F};
  Rational gain_max_metadata{0, 1};
  Rational gamma_metadata{1, 1};
};

// Exact distribution of an 8-bit gain grid, using 256 counts instead of a
// decoded full-grid copy and sort. Ceiling is the requested output budget;
// zero disables the clipping counter for measured, unconstrained ratios.
void measure_quantized_gain(RenderStats& stats, const FloatImage& codes,
                            float gain_max, float gamma, float ceiling,
                            float gain_min = 0.0F);

[[nodiscard]] float encode_gain_code(float normalized_gain, float gamma);
[[nodiscard]] float decode_gain_code(float encoded_gain, float gamma);

// Quantizes an already gamma-encoded gain value into the normalized 8-bit
// gain-map code space. The zero code bucket and the first represented code
// stay stable: bilinear upsampling must not turn a near-knee value into a
// visible shadow gain just because of dithering. The maximum code remains 1.
[[nodiscard]] float quantize_gain_code_dithered(float encoded_gain,
                                                std::uint32_t x,
                                                std::uint32_t y);

// Picks the gamma that minimises weighted 8-bit round-trip error over the
// grid's own distribution, preferring 1 when the difference is immaterial so
// the metadata stays simple.
[[nodiscard]] float choose_gain_gamma(const std::vector<float>& normalized_gains);

// Encodes a non-negative log2-gain grid with the same 8-bit representation and
// serializable rational metadata used by every scalar gain-map writer.
[[nodiscard]] QuantizedGainGrid quantize_gain_grid(
    const std::vector<float>& gain_stops, std::uint32_t width);

}  // namespace hyperdr
