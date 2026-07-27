#pragma once

// Which input files a run will convert, and where each one's output goes.
//
// The subtle part is a conversion whose output directory is its own input
// directory, or nested inside it: without care the run either converts its own
// output or walks into it forever. Both cases are excluded here rather than in
// the loop that opens files.

#include "hyperdr/app/settings.hpp"

#include <filesystem>
#include <vector>

namespace hyperdr {

// Extensions the converter accepts, lowercase and including the dot.
[[nodiscard]] std::vector<std::string_view> supported_input_extensions();
[[nodiscard]] bool is_supported_input(const std::filesystem::path& path);

// Throws when the input does not exist or contains no supported image.
[[nodiscard]] std::vector<std::filesystem::path> discover_input_files(
    const ConvertOptions& options);

// Mirrors the input's relative path under the output directory, with the
// converter's own suffix and the encoding's extension.
[[nodiscard]] std::filesystem::path output_path_for(const std::filesystem::path& input,
                                                   const ConvertOptions& options);

}  // namespace hyperdr
