#include "hyperdr/look/options.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>
#include <string_view>

namespace hyperdr {
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



}  // namespace hyperdr
