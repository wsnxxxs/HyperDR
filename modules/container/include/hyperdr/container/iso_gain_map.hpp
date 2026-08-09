#pragma once

// ISO/IEC 21496-1 gain-map metadata: the struct, and the `tmap` payload it is
// stored as.
//
// This is a serialized metadata format, so it sits beside the other two the
// project reads and writes -- Exif and the HEIF box tree -- rather than in the
// renderer. Structural inspection needs to validate the payload, and the
// renderer needs to produce it, so putting it here is what lets both happen
// without either depending on the other.

#include "hyperdr/foundation/rational.hpp"

#include <cstddef>
#include <cstdint>
#include <vector>

namespace hyperdr {

struct GainMapChannelMetadata {
  Rational gain_min{0, 1};
  Rational gain_max{1, 1};
  Rational gamma{1, 1};
  Rational base_offset{0, 1};
  Rational alternate_offset{0, 1};
};

struct GainMapMetadata {
  std::uint16_t minimum_version{0};
  std::uint16_t writer_version{0};
  std::uint8_t flags{0x40};
  Rational gain_min{0, 1};
  Rational gain_max{1, 1};
  Rational gamma{1, 1};
  // Zero offsets are required for a strict common-RGB-scale reconstruction.
  Rational base_offset{0, 1};
  Rational alternate_offset{0, 1};
  Rational base_headroom{0, 1};
  Rational alternate_headroom{1, 1};
  bool use_base_color_space{true};
  bool backward_direction{false};
  bool common_denominator{false};
  // ISO 21496-1 repeats the five coding rationals for each channel while the
  // two headrooms remain global. The long-standing flat fields above are the
  // canonical single-channel representation. A multichannel record sets flag
  // 0x80 and stores exactly three entries here; mixing the two forms is
  // rejected so no caller can silently fall back to channel zero.
  std::vector<GainMapChannelMetadata> channels;
};

enum class GainMapWriterProfile {
  iso_generic,
  apple_strict,
};

[[nodiscard]] std::size_t gain_map_channel_count(
    const GainMapMetadata& metadata);
[[nodiscard]] GainMapChannelMetadata gain_map_channel(
    const GainMapMetadata& metadata, std::size_t index);
void validate_gain_map_metadata(
    const GainMapMetadata& metadata,
    GainMapWriterProfile profile = GainMapWriterProfile::iso_generic);

[[nodiscard]] std::vector<std::uint8_t> serialize_tmap_payload(
    const GainMapMetadata& metadata);

// Strict structural parser. `iso_generic` accepts the standard's one- and
// three-channel forms. `apple_strict` additionally requires one channel and
// Apple's observed gain_max == alternate_headroom writer convention.
[[nodiscard]] GainMapMetadata parse_tmap_payload(
    const std::vector<std::uint8_t>& payload,
    GainMapWriterProfile profile = GainMapWriterProfile::iso_generic);

}  // namespace hyperdr
