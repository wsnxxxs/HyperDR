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

#include <cstdint>
#include <vector>

namespace hyperdr {

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
};

[[nodiscard]] std::vector<std::uint8_t> serialize_tmap_payload(
    const GainMapMetadata& metadata);

// Strict: rejects unsupported versions, reserved flags, multichannel maps,
// implausible ranges, and trailing bytes in a version-zero payload. A file that
// only nearly conforms is a file some other decoder will render differently.
[[nodiscard]] GainMapMetadata parse_tmap_payload(
    const std::vector<std::uint8_t>& payload);

}  // namespace hyperdr
