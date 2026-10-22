#pragma once

#include <filesystem>
#include <string>

namespace hyperdr {

// Runtime round-trip verification of the sole HEVC encoder, VideoToolbox.
struct EncoderCapabilities {
  bool main8{}, main10{};
  std::string reason;
};
[[nodiscard]] EncoderCapabilities encoder_capabilities(
    const std::filesystem::path& cache_directory = {});

}  // namespace hyperdr
