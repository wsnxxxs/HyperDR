#pragma once

#include "hyperdr/container/iso_gain_map.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace hyperdr {
struct JpegAppSegment {
  std::uint8_t marker{};
  std::size_t offset{};  // Marker offset in the complete file.
  std::vector<std::uint8_t> payload;
};
struct JpegMpEntry {
  std::uint32_t attributes{}, size{}, offset{};
};
struct GainMapJpeg {
  std::array<std::vector<JpegAppSegment>, 2> app_segments;
  std::array<JpegMpEntry, 2> entries;
  std::size_t primary_size{}, gain_offset{}, gain_size{};
  std::size_t primary_iso_count{}, gain_iso_count{}, mpf_count{};
  std::uint16_t minimum_version{}, writer_version{};
  GainMapMetadata metadata;
  bool has_hdrgm{}, has_container_directory{};
};
[[nodiscard]] std::vector<std::uint8_t> assemble_gain_map_jpeg(
    const std::vector<std::uint8_t>& primary,
    const std::vector<std::uint8_t>& gain, const GainMapMetadata& metadata);
// Validates JPEG marker boundaries, MP Index ranges and ISO metadata before
// exposing any offsets. Entropy-coded image data is checked by the codec layer.
[[nodiscard]] GainMapJpeg parse_gain_map_jpeg(const std::vector<std::uint8_t>& bytes);
}  // namespace hyperdr
