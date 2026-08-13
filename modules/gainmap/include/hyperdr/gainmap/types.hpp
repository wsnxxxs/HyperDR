#pragma once

// The gain-map rendition: an SDR base image, a single-channel gain map, the
// ISO 21496-1 metadata that relates them, and the measurements a run reports.

#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/rational.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/look/options.hpp"

#include <array>
#include <cstdint>
#include <optional>

namespace hyperdr {

struct GainMapOptions {
  bool auto_exposure{true};
  float exposure_ev{0.0F};
  // Creative offset applied after automatic or manual exposure selection.
  // Unlike HDR gain controls, this moves the SDR base and HDR rendition together.
  //
  // Zero, which is what the documentation has always said and what the panel
  // has always sent explicitly. It defaulted to +1 EV here, so a bare
  // `HyperDR convert` brightened every file by a stop that nothing in the run
  // reported as a decision -- least visibly on a display-referred input, where
  // it also pushed diffuse white into the top codes of the SDR base.
  float exposure_bias_ev{0.0F};
  bool auto_headroom{true};
  float headroom_stops{3.0F};
  float gain_strength{1.0F};
  // Optional cap used only when an external/model gain map is replayed. It is
  // deliberately separate from `headroom_stops`: the model's development
  // recipe must remain intact so its SDR base stays reproducible, while the
  // selected output format may still impose a lower display ceiling.
  float output_headroom_limit_stops{-1.0F};
  LookOptions look{};
};

// Validates the renderer's own controls, then the look's, before any RAW decode
// or image allocation happens: a rejected setting should cost nothing.
void validate_gain_map_options(const GainMapOptions& options);

// The headroom the exported curve represents. Automatic headroom is content
// dependent, so a curve built without an image uses the configured ceiling.
[[nodiscard]] float nominal_headroom_stops(const GainMapOptions& options);

// Everything a run measured, as opposed to everything it was asked for. The
// report is the only consumer, and it is the record used to tell a look change
// from a content change when two conversions differ.
struct RenderStats {
  float exposure_ev{0.0F};
  std::optional<float> ev100;
  float target_middle_gray{0.18F};

  float headroom_stops{0.0F};
  float headroom_linear{1.0F};
  float rendered_peak{1.0F};
  float headroom_utilization{0.0F};

  float gain_min_stops{0.0F};
  float gain_max_stops{0.0F};
  float gain_gamma{1.0F};
  std::array<float, 8> gain_percentiles{};
  float gain_fraction_gt_0_5{0.0F};
  float gain_fraction_gt_1_0{0.0F};
  float gain_fraction_gt_2_0{0.0F};
  float gain_clipped_fraction{0.0F};

  float local_weight_mean{1.0F};
  float local_weight_p95{1.0F};
  float below_knee_relative_difference_max{0.0F};
  // Input-domain fraction of sufficiently bright, linear Display P3 pixels
  // whose chromaticity lies outside Rec.709. It is measured before exposure
  // or look rendering, so it isolates the decoded wide-gamut input from
  // contrast, vibrance, and pop.
  float wide_gamut_fraction{0.0F};
  std::uint64_t wide_gamut_pixels{0};
  std::uint64_t wide_gamut_eligible_pixels{0};
  float wide_gamut_luminance_threshold{0.02F};
};

struct GainMapResult {
  FloatImage base_linear;
  FloatImage gain_map;
  GainMapMetadata metadata;
  float exposure_ev{};
  float headroom_stops{};
  RenderStats stats;
};

}  // namespace hyperdr
