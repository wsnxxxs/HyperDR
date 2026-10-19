#pragma once

// Reading the ISO/IEC 23008-12 tone-mapped derived image ('tmap') back out of a
// HEIC the writer produced: its ISO 21496-1 payload and its ordered references.
// Both go through the container reader, so they accept what the reader accepts.

#include <cstdint>
#include <vector>

namespace hyperdr {

struct TmapReferences {
  std::uint32_t tmap_id{};
  std::uint32_t base_id{};
  std::uint32_t gain_id{};
};

// The tmap item's ISO 21496-1 payload.
[[nodiscard]] std::vector<std::uint8_t> extract_tmap_payload(
    const std::vector<std::uint8_t>& bytes);
// The tmap item's ordered dimg references [base, gain map].
[[nodiscard]] TmapReferences find_tmap_references(
    const std::vector<std::uint8_t>& bytes);

}  // namespace hyperdr
