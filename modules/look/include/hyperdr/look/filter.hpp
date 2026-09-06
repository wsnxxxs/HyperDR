#pragma once

// Box mean and edge-aware guided filter over the gain grid.
//
// Both take caller-owned scratch buffers rather than allocating: a conversion
// runs them a dozen times over grids of a few megabytes, and the allocation
// traffic was measurable next to the arithmetic.

#include <cstdint>
#include <vector>

namespace hyperdr {

// Separable sliding-window box mean over a (2*radius+1) window. `integral`
// retains the existing scratch contract: (width+1) * (height+1) doubles.
// It stores horizontal sums; double precision keeps local means stable.
void box_mean(const std::vector<float>& input, std::vector<float>& output,
              std::uint32_t width, std::uint32_t height, std::uint32_t radius,
              std::vector<double>& integral);

// Edge-aware guided filter that keeps the per-cell gain within
// [0, global_gain], so a smoothed gain never exceeds the global-curve target
// for that cell and highlight expansion cannot leak across a hard edge.
void guided_filter_gain(std::vector<float>& gain,
                        const std::vector<float>& global_gain,
                        const std::vector<float>& guide, std::uint32_t width,
                        std::uint32_t height, std::vector<float>& mean_i,
                        std::vector<float>& mean_p, std::vector<float>& work_one,
                        std::vector<float>& work_two,
                        std::vector<double>& integral);

}  // namespace hyperdr
