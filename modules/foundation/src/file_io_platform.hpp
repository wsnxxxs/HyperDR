#pragma once

#include <cstddef>
#include <filesystem>

namespace hyperdr::detail {

void write_bytes_atomic(const std::filesystem::path& path, const char* data,
                        std::size_t size, bool overwrite);

}  // namespace hyperdr::detail
