#pragma once

// Turning a two-image HEIF into an ISO/IEC 23008-12 tone-mapped derived image.
//
// libheif can write a primary image and a second image, but it will not relate
// them as base plus gain map. This is the surgery that does: the 'tmap'
// compatible brand is appended to ftyp (shifting media data by at most one brand
// slot, with every item location rewritten accordingly), a replacement meta box
// and a small metadata mdat are appended, and the original meta box becomes a
// same-size free box so no offset outside it has to move.

#include <cstdint>
#include <vector>

namespace hyperdr {

struct TmapReferences {
  std::uint32_t tmap_id{};
  std::uint32_t base_id{};
  std::uint32_t gain_id{};
};

[[nodiscard]] std::vector<std::uint8_t> add_tmap_to_two_image_heif(
    const std::vector<std::uint8_t>& source,
    const std::vector<std::uint8_t>& tmap_payload);

// Reads back what the rewrite wrote: the ISO 21496-1 payload, and the tmap
// item's ordered dimg references [base, gain map].
[[nodiscard]] std::vector<std::uint8_t> extract_tmap_payload(
    const std::vector<std::uint8_t>& bytes);
[[nodiscard]] TmapReferences find_tmap_references(
    const std::vector<std::uint8_t>& bytes);

}  // namespace hyperdr
