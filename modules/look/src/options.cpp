#include "hyperdr/look/options.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
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
        look.toe_output_ratio >= 1.0F / 3.0F &&
        look.toe_output_ratio < 1.0F &&
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

const char* input_domain_name(InputDomain domain) {
  switch (domain) {
    case InputDomain::kSceneReferred: return "scene-referred";
    case InputDomain::kDisplayReferredSdr: return "display-referred-sdr";
    case InputDomain::kDisplayReferredHdr: return "display-referred-hdr";
    case InputDomain::kDualRendition: return "dual-rendition";
    case InputDomain::kUnknown: return "unknown";
  }
  return "unknown";
}

std::optional<InputDomain> input_domain_from_name(std::string_view name) {
  if (name == "scene-referred") return InputDomain::kSceneReferred;
  if (name == "display-referred-sdr") return InputDomain::kDisplayReferredSdr;
  if (name == "display-referred-hdr") return InputDomain::kDisplayReferredHdr;
  if (name == "dual-rendition") return InputDomain::kDualRendition;
  if (name == "unknown") return InputDomain::kUnknown;
  return std::nullopt;
}

float rendering_headroom(const InputDescription& input) {
  // Dual inputs already carry a measured peak of the restored alternate.
  if (input.domain != InputDomain::kDisplayReferredHdr || !input.content_peak_nits)
    return input.headroom;
  return std::clamp(*input.content_peak_nits / kReferenceWhiteNits, 1.0F, input.headroom);
}

void validate_input_description(const InputDescription& input) {
  if (input.domain == InputDomain::kUnknown) {
    throw std::invalid_argument("input domain is unknown");
  }
  if (!std::isfinite(input.headroom) || input.headroom < 1.0F) {
    throw std::invalid_argument("input headroom must be finite and at least 1");
  }
  if (input.content_peak_nits &&
      (!std::isfinite(*input.content_peak_nits) || *input.content_peak_nits <= 0)) {
    throw std::invalid_argument("content peak must be finite and positive");
  }
  // The encoding must carry HDR range. Content-light metadata can separately
  // limit rendering to unit headroom without changing the input domain.
  if (input.domain == InputDomain::kDisplayReferredHdr && input.headroom <= 1.0F) {
    throw std::invalid_argument(
        "a display-referred HDR input must declare headroom above 1");
  }
  if (input.domain != InputDomain::kDisplayReferredHdr && input.domain != InputDomain::kDualRendition && input.headroom != 1.0F) {
    throw std::invalid_argument(
        "only a display-referred HDR input may declare headroom");
  }
  if (input.domain == InputDomain::kDualRendition) {
    if (!input.authored_sdr || (input.gain_map.channels != 1 && input.gain_map.channels != 3) ||
        !std::isfinite(input.gain_map.base_headroom) ||
        !std::isfinite(input.gain_map.alternate_headroom) ||
        input.gain_map.base_headroom < 1 ||
        input.gain_map.alternate_headroom < input.gain_map.base_headroom) {
      throw std::invalid_argument("dual rendition requires an SDR base and valid gain metadata");
    }
    for (int c = 0; c < 3; ++c) {
      if (!std::isfinite(input.gain_map.base_offset[c]) ||
          !std::isfinite(input.gain_map.alternate_offset[c]) ||
          input.gain_map.base_offset[c] < 0 || input.gain_map.alternate_offset[c] < 0)
        throw std::invalid_argument("dual rendition gain offsets must be finite and nonnegative");
    }
  }
}

void validate_look_options(const LookOptions& options) {
  validate_photographic_controls(options);
}

}  // namespace hyperdr
