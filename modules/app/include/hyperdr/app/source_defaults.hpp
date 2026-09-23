#pragma once

#include "hyperdr/look/options.hpp"

namespace hyperdr {

// The source identity used by both preview packet formats and the panel reset.
struct SourceDefaults {
  float brightness_ev{};
  float hdr_strength{};
  float hdr_range_stops{};
  float area_coverage{};
  float lut_strength{};
};

[[nodiscard]] constexpr SourceDefaults source_defaults(InputDomain domain) noexcept {
  if (domain == InputDomain::kDisplayReferredHdr ||
      domain == InputDomain::kDualRendition) {
    return {0.0F, 1.0F, 4.0F, 1.0F, 0.0F};
  }
  return {0.0F, 0.0F, 0.0F, 0.0F, 0.0F};
}

}  // namespace hyperdr
