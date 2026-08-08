#include "hyperdr/look/options.hpp"

#include <cmath>
#include <stdexcept>
#include <string_view>

namespace hyperdr {
namespace {

// Photographic-only creative controls. Neutral mode never reads them, and
// rejecting a value it will ignore would turn a harmless leftover flag into a
// hard failure.
void validate_photographic_controls(const LookOptions& look) {
  if (!(std::isfinite(look.contrast) && look.contrast >= 0.80F &&
        look.contrast <= 1.35F)) {
    throw std::invalid_argument("photographic contrast must be in [0.80, 1.35]");
  }
  if (!(std::isfinite(look.vibrance) && look.vibrance >= -0.50F &&
        look.vibrance <= 0.50F)) {
    throw std::invalid_argument("photographic vibrance must be in [-0.50, 0.50]");
  }
  if (!(std::isfinite(look.pop) && look.pop >= 0.0F && look.pop <= 1.0F)) {
    throw std::invalid_argument("photographic pop must be in [0, 1]");
  }
  if (!(std::isfinite(look.headroom_max_stops) && look.headroom_max_stops >= 0.0F &&
        look.headroom_max_stops <= 4.0F)) {
    throw std::invalid_argument("photographic headroom maximum must be in [0, 4]");
  }
  if (!(std::isfinite(look.shoulder_start) && look.shoulder_start >= 0.18F &&
        look.shoulder_start <= 0.75F)) {
    throw std::invalid_argument("photographic expansion start must be in [0.18, 0.75]");
  }
  if (!(std::isfinite(look.diffuse_gain_floor) && look.diffuse_gain_floor >= 0.0F &&
        look.diffuse_gain_floor <= 1.0F)) {
    throw std::invalid_argument("photographic area coverage must be in [0, 1]");
  }
  if (!(std::isfinite(look.toe_end) && std::isfinite(look.toe_output_ratio) &&
        std::isfinite(look.positive_exposure_limit_ev) && look.toe_end > 0.0F &&
        look.toe_output_ratio > 0.0F && look.toe_output_ratio < 1.0F &&
        look.positive_exposure_limit_ev >= 0.0F)) {
    throw std::invalid_argument("invalid internal photographic-look parameters");
  }
}

}  // namespace

const char* look_mode_name(LookMode mode) {
  switch (mode) {
    case LookMode::kPhotographic: return "photographic";
  }
  return "unknown";
}

std::optional<LookMode> look_mode_from_name(std::string_view name) {
  if (name == "photographic") return LookMode::kPhotographic;
  return std::nullopt;
}

void validate_look_options(const LookOptions& options) {
  validate_photographic_controls(options);
}

}  // namespace hyperdr
