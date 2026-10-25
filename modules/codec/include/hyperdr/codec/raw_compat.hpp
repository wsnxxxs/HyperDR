#pragma once

// Compatibility for camera RAW files the system RAW engine cannot develop.
// LibRaw only unpacks these files; the system develops the resulting DNG.

#include "hyperdr/foundation/cancel.hpp"

#include <filesystem>
#include <stdexcept>
#include <string>

namespace hyperdr {

class RawNoPreview : public std::runtime_error {
 public:
  RawNoPreview() : std::runtime_error("RAW file has no embedded JPEG preview") {}
};

// Static identity of the exact LibRaw snapshot and DNG serialization format.
[[nodiscard]] const char* raw_converter_id() noexcept;

// The report is a JSON object. Output paths are never overwritten: bytes are
// written beside the destination and published with a no-replace rename.
[[nodiscard]] std::string raw_convert_dng(const std::filesystem::path& raw_path,
                                          const std::filesystem::path& dng_path);
[[nodiscard]] std::string raw_extract_preview(const std::filesystem::path& raw_path,
                                              const std::filesystem::path& jpeg_path);

}  // namespace hyperdr
