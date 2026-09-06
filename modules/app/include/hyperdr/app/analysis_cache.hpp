#pragma once

#include "hyperdr/gainmap/gain_map.hpp"

#include <filesystem>

namespace hyperdr {

// The file identity comes from decode_cached_image: source digest, decode
// settings and size bound. Look controls intentionally do not enter this key.
PhotographicAnalysis cached_photographic_analysis(
    const FloatImage& source, const std::filesystem::path& file,
    std::uint64_t budget_bytes, bool* cache_hit = nullptr);

}  // namespace hyperdr
