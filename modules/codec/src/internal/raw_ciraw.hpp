#pragma once
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
