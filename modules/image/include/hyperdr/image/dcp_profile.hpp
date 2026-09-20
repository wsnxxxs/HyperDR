#pragma once
#include "hyperdr/image/dng_color.hpp"
#include <memory>
#include <string>
#include <vector>

namespace hyperdr {
struct DcpHueSatMap {
  std::array<std::uint32_t, 3> dims{};
  std::vector<std::array<float, 3>> values;
  bool srgb_encoding{false};
};
struct DcpProfile {
  std::string name, camera_model, calibration_signature, copyright, sha256;
  DngColorProfile color;
  std::array<DcpHueSatMap, 2> hue_sat_maps;
  DcpHueSatMap look_table;
  std::vector<std::array<double, 2>> tone_curve;
  float baseline_exposure_offset{0};
  bool default_black_render_none{false};
};
struct DcpRenderContext {
  std::shared_ptr<const DcpProfile> profile;
  // Weight of the original first calibration/map, before temperature sorting.
  double illuminant_weight{1};
  float baseline_exposure{0};
};
}  // namespace hyperdr
