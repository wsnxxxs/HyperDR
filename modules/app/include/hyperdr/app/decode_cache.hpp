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
// no daemon. Entries are keyed by the source content and decode recipe, and a
// corrupt or truncated file is simply a miss.

#include "hyperdr/app/settings.hpp"

#include <cstdint>
#include <filesystem>
#include <string>

namespace hyperdr {

// Identifies one decode result. `variant` must encode every option that can
// change the decoded pixels: highlight recovery, half-size demosaic, and the
// preview bound.
//
// The source identity includes its content digest. A caller such as the panel
// that already hashed an upload may pass it to avoid a second 300 MB read;
// standalone CLI callers leave it empty and get the same correctness by hashing
// here.
[[nodiscard]] std::string decode_cache_key(const std::filesystem::path& input,
                                           std::string_view variant,
                                           std::string_view source_sha256 = {});

// Builds the decode-only cache variant from the same settings table used by
// the CLI and report. Look and encoding controls are excluded; RAW development
// controls, the preview size, and calibration resources are included.
[[nodiscard]] std::string decode_cache_variant(
    const ConvertOptions& options, const RawDecodeOptions& raw);

// Decode and apply the requested pre-look size bound, reusing the optional
// on-disk cache. Both batch conversion and `preview-frame` go through this
// entry point so the panel cannot accidentally bypass the cache again.
[[nodiscard]] DecodedImage decode_cached_image(
    const std::filesystem::path& input, const ConvertOptions& options,
    const RawDecodeOptions& raw);

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
