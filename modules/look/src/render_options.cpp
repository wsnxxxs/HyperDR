#include "hyperdr/look/rendition.hpp"
#include <cmath>
#include <stdexcept>
namespace hyperdr {
RenderOptions render_options_for_target(RenderOptions options, RenderTarget target) {
  if(target==RenderTarget::Sdr) {
    // SDR development, including RAW exposure selection, must not depend on
    // HDR range/strength retained by the UI. Keep the shared base curve.
    options.auto_headroom=false; options.headroom_stops=0;
    options.gain_strength=0; options.look.headroom_max_stops=0;
    options.look.diffuse_gain_floor=0;
  }
  return options;
}

void validate_render_options(const RenderOptions& options) {
  if (!(std::isfinite(options.gain_strength) && options.gain_strength >= 0.0F &&
        options.gain_strength <= 2.0F)) {
    throw std::invalid_argument("gain strength must be in [0, 2]");
  }
  if (!std::isfinite(options.output_headroom_limit_stops) ||
      (options.output_headroom_limit_stops >= 0.0F &&
       options.output_headroom_limit_stops > 4.0F)) {
    throw std::invalid_argument(
        "output headroom limit must be negative or in [0, 4]");
  }
  if (!options.auto_exposure && !std::isfinite(options.exposure_ev)) {
    throw std::invalid_argument("manual exposure must be finite");
  }
  if (!(std::isfinite(options.exposure_bias_ev) && options.exposure_bias_ev >= 0.0F &&
        options.exposure_bias_ev <= 2.0F)) {
    throw std::invalid_argument("exposure bias must be in [0, 2]");
  }
  validate_look_options(options.look);
  if (options.auto_headroom) return;
  // The photographic renderer treats headroom-max as a hard ceiling, so an
  // explicit target above it would silently be clamped instead of honoured.
  if (!(std::isfinite(options.headroom_stops) && options.headroom_stops >= 0.0F &&
        options.headroom_stops <= options.look.headroom_max_stops)) {
    throw std::invalid_argument(
        "manual photographic headroom must be in [0, headroom-max]");
  }
}

}  // namespace hyperdr
