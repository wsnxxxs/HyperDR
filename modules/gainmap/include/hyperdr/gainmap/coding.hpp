#pragma once

// How a gain value becomes a stored code, and back.
//
// ISO 21496-1 decodes a stored code with pow(code, 1 / gamma). Keeping both
// directions and the gamma search here makes the convention directly testable,
// and means the encoder and the verifier cannot disagree about it.

#include <vector>

namespace hyperdr {

[[nodiscard]] float encode_gain_code(float normalized_gain, float gamma);
[[nodiscard]] float decode_gain_code(float encoded_gain, float gamma);

// Picks the gamma that minimises weighted 8-bit round-trip error over the
// grid's own distribution, preferring 1 when the difference is immaterial so
// the metadata stays simple.
[[nodiscard]] float choose_gain_gamma(const std::vector<float>& normalized_gains);

}  // namespace hyperdr
