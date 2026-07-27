#pragma once

// Whole-file binary reads and crash-safe writes, plus the path comparison rules
// every caller has to agree on.
//
// These lived in bmff.hpp, so a codec front-end that only wanted to write bytes
// had to include the HEIF box parser to get them, and `container` became a
// dependency of everything. Path comparison had drifted into two copies -- one
// in cli.cpp as `same_path`, one in pipeline.cpp as `normalized_path_key` --
// which had to agree for `--reconstruct` refusing to overwrite its input to
// actually hold.

#include <cstdint>
#include <filesystem>
#include <string>
#include <vector>

namespace hyperdr {

[[nodiscard]] std::vector<std::uint8_t> read_binary_file(const std::filesystem::path& path);

// Writes to a uniquely named temporary in the destination directory and then
// renames it into place, so an interrupted run never leaves a half-written
// image where a complete one is expected.
void write_binary_file_atomic(const std::filesystem::path& path,
                              const std::vector<std::uint8_t>& bytes,
                              bool overwrite);

void write_text_file_atomic(const std::filesystem::path& path,
                            std::string_view text, bool overwrite);

// UTF-8 text for messages and JSON. `path::string()` throws on Windows for
// paths outside the active code page, which is most of them for CJK users.
[[nodiscard]] std::string path_utf8(const std::filesystem::path& path);

// Windows path comparison keys use native wide strings and fold case.
using PathKey = std::wstring;

[[nodiscard]] PathKey path_key(const std::filesystem::path& path);
[[nodiscard]] bool same_path(const std::filesystem::path& left,
                             const std::filesystem::path& right);
[[nodiscard]] bool is_same_or_descendant(const std::filesystem::path& path,
                                         const std::filesystem::path& directory);

// Lowercased extension including the leading dot, for case-insensitive format
// dispatch. ASCII only: no supported image extension is non-ASCII.
[[nodiscard]] std::string lower_extension(const std::filesystem::path& path);

// Bytes of physical memory currently available, or 0 if Windows cannot report it.
[[nodiscard]] std::uint64_t available_memory_bytes();

}  // namespace hyperdr
