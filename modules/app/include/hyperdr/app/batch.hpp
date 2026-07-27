#pragma once

// Running one conversion, and running many sequentially.

#include "hyperdr/app/settings.hpp"

#include <vector>

namespace hyperdr {

// Enforces the non-degradable resolution contract before any gain-map work or
// output allocation begins. Public so the invariant has a fixture-free test.
void require_decode_resolution(const ConvertOptions& options,
                               const DecodeInfo& decode);

// Decodes, renders, encodes, verifies and publishes one file. Never throws for a
// per-file failure: the reason lands in the result so a batch can continue.
[[nodiscard]] FileResult convert_file(const std::filesystem::path& input,
                                      const ConvertOptions& options,
                                      const std::string& fingerprint);

// Converts everything `discover_input_files` finds. Returns a process exit code:
// 0 when every file succeeded or was skipped.
[[nodiscard]] int run_conversion(const ConvertOptions& options);

}  // namespace hyperdr
