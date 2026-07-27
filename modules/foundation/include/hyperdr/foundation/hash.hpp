#pragma once

// FNV-1a over text, rendered as fixed-width hex.
//
// Used for the resumable-batch settings fingerprint and the decode-cache key.
// It is not a security primitive; it is a compact, stable, dependency-free way
// to notice that two sets of settings differ.

#include <filesystem>
#include <string>
#include <string_view>

namespace hyperdr {

[[nodiscard]] std::string fnv1a_hex(std::string_view text);
[[nodiscard]] std::string sha256_file_hex(const std::filesystem::path& path);

}  // namespace hyperdr
