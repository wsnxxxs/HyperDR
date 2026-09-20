#pragma once

// How far a decoded HDR image is from the image it was converted from.
//
// "Lossless" is a claim about what a viewer would see, so it is measured in the
// space built for exactly that question: ITU-R BT.2124 ΔE ITP, computed from
// BT.2100 ICtCp with diffuse white at 203 cd/m², where 1.0 is roughly one
// just-noticeable difference. A PSNR over PQ-encoded BT.2020 RGB is reported
// beside it because it is the figure HDR codec comparisons conventionally
// quote, and the luminance peaks show whether highlight range survived at all
// -- a file can have a small mean error and still have lost its brightest
// stop.
//
// Both images are linear Display P3 relative to diffuse white, the pipeline's
// one working space, and must have identical dimensions.

#include "hyperdr/image/image.hpp"

#include <array>
#include <cstdint>

namespace hyperdr {

struct HdrFidelity {
  std::uint64_t pixels{0};

  double delta_e_itp_mean{0.0};
  float delta_e_itp_p50{0.0F};
  float delta_e_itp_p95{0.0F};
  float delta_e_itp_p99{0.0F};
  float delta_e_itp_p999{0.0F};
  float delta_e_itp_max{0.0F};
  double fraction_above_1{0.0};
  double fraction_above_2{0.0};
  double fraction_above_5{0.0};

  // Infinite when the two PQ-encoded images are identical.
  double psnr_pq_db{0.0};

  // P3 luminance, relative to diffuse white.
  float reference_peak{0.0F};
  float candidate_peak{0.0F};
  double reference_mean{0.0};
  double candidate_mean{0.0};

  // Mean ΔE ITP by reference luminance: shadows below 0.18, midtones up to
  // diffuse white, and highlights above it -- the band a gain map exists for.
  static constexpr std::array<float, 2> kBandEdges{0.18F, 1.0F};
  std::array<double, 3> band_delta_e_itp_mean{};
  std::array<std::uint64_t, 3> band_pixels{};
};

// ΔE ITP between two linear-P3 colours relative to diffuse white.
[[nodiscard]] float delta_e_itp(const std::array<float, 3>& reference,
                                const std::array<float, 3>& candidate);

[[nodiscard]] HdrFidelity measure_hdr_fidelity(const FloatImage& reference,
                                               const FloatImage& candidate);

}  // namespace hyperdr
