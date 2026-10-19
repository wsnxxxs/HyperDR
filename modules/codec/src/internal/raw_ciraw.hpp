#pragma once
#include "hyperdr/codec/image_source.hpp"
#include <cstdint>
#include <functional>
#include <string>
namespace hyperdr::testing {
std::uint64_t raw_filter_open_count();
std::uint64_t raw_filter_render_count();
void set_raw_os_build_override(std::string value);
// Runs after the non-interruptible open and before its cancellation check.
void set_raw_open_hook(std::function<void()> hook);
std::string raw_neutral_settings();
void set_raw_block_hook(std::function<void(unsigned, unsigned)> hook);
}  // namespace hyperdr::testing

namespace hyperdr::codec {
[[nodiscard]] DecodedImage decode_apple_raw(const std::filesystem::path& path,
                                          const RawDecodeOptions& options = {});
}
