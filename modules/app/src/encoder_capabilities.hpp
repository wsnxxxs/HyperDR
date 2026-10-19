#pragma once

#include "hyperdr/codec/encoder_capabilities.hpp"
#include <stdexcept>
#include <string_view>

namespace hyperdr::app::detail {
inline void validate_hevc_override(std::string_view value) {
  if (!value.empty() && value != "unavailable" && value != "no-main10")
    throw std::invalid_argument("hevc_override must be unavailable or no-main10");
}
inline EncoderCapabilities effective_encoder_capabilities(
    const std::filesystem::path& cache, std::string_view override_value) {
  validate_hevc_override(override_value);
  if (override_value == "unavailable") return {false, false, "hevc_unavailable"};
  auto caps = encoder_capabilities(cache);
  if (override_value == "no-main10" && caps.main8) {
    caps.main10 = false;
    caps.reason = "hevc_main10_unavailable";
  }
  return caps;
}
inline std::string encoder_failure(const EncoderCapabilities& caps, bool main10) {
  if (!caps.main8) return caps.reason.empty() ? "hevc_unavailable" : caps.reason;
  if (main10 && !caps.main10) return "hevc_main10_unavailable";
  return {};
}
}  // namespace hyperdr::app::detail
