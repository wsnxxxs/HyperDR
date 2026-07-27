#pragma once

// A decoded-image cache for interactive preview.
//
// Moving any look slider in the panel re-runs the converter, and the RAW
// decode dominates that run even at --preview-max-edge. Contrast, vibrance,
// pop, headroom, expansion start and area coverage all act *after* the decode,
// so re-reading the sensor data for each of them is pure waste. Keying the
// post-resample linear Display-P3 buffer on the decode-affecting inputs alone
// lets every subsequent slider move skip LibRaw entirely.
//
// The cache is a plain directory of self-describing files rather than process
// state, so it survives the converter being a short-lived subprocess and needs
// no daemon. Entries are validated against the source file's size and
// modification time, and a corrupt or truncated file is simply a miss.

#include "hyperdr/codec/image_source.hpp"

#include <cstdint>
#include <filesystem>
#include <string>

namespace hyperdr {

// Identifies one decode result. `variant` must encode every option that can
// change the decoded pixels: highlight recovery, half-size demosaic, and the
// preview bound.
//
// The key includes a content hash of the input, so replacing a file with
// different pixels at the same size and modification time is a miss. That
// costs one sequential read of the source per lookup, which is small against
// the decode it is protecting.
[[nodiscard]] std::string decode_cache_key(const std::filesystem::path& input,
                                           std::string_view variant);

[[nodiscard]] std::filesystem::path decode_cache_path(
    const std::filesystem::path& directory, const std::string& key);

// Returns false on any miss: absent file, wrong magic or version, truncated
// payload, or dimensions that disagree with the payload length.
[[nodiscard]] bool read_decode_cache(const std::filesystem::path& file, DecodedImage& out);

// Writes atomically. Failures are reported so callers can decide whether to
// warn; a failed write never invalidates the conversion itself.
//
// A non-zero `budget_bytes` prunes the containing directory after the write,
// so the limit holds for the entries a run creates and not only for the ones
// it inherited.
[[nodiscard]] bool write_decode_cache(const std::filesystem::path& file,
                                      const DecodedImage& value,
                                      std::uint64_t budget_bytes = 0);

// Deletes least-recently-modified entries until the directory fits the budget.
void prune_decode_cache(const std::filesystem::path& directory,
                        std::uint64_t budget_bytes);

}  // namespace hyperdr
