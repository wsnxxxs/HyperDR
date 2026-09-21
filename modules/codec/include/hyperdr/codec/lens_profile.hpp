#pragma once
#include "hyperdr/image/image.hpp"
#include <array>
#include <filesystem>
#include <limits>
#include <optional>
#include <string>
#include <vector>

namespace hyperdr {
struct LensModel {
  double fx{1}, fy{1}, cx{0.5}, cy{0.5};
  std::array<double, 3> radial{};
  std::array<double, 2> tangential{};
  double residual_error{std::numeric_limits<double>::infinity()};
};
struct LensCalibration {
  double focal_length{}, aperture_value{};
  LensModel distortion;
  std::optional<LensModel> vignette;
  double focus_distance{};
};
struct LensProfile {
  std::vector<LensCalibration> calibrations;
};
[[nodiscard]] LensProfile read_lens_profile(const std::filesystem::path& path);
// The LibRaw orientation is accounted for in sensor coordinates. The scalar
// vignette gain is applied to linear pixels and commutes with the colour matrix.
// Geometry uses bounded Catmull-Rom interpolation; vignette-only profiles are
// applied in place without resampling. Output dimensions are preserved.
[[nodiscard]] std::string apply_lens_profile(FloatImage& image,
    const LensProfile& profile, double focal_length, double aperture, int flip);
}  // namespace hyperdr
