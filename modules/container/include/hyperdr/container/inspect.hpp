#pragma once

// Structural inspection of a HEIF file, without a codec.
//
// `HyperDR verify` and the conversion self-check both need to answer "is this
// really a gain-map HEIC" from the bytes alone, before any decoder is involved.
// Parsing the box tree directly is what makes that answer independent of
// whichever libheif version happens to be installed.

#include <cstdint>
#include <string>
#include <vector>

#include "hyperdr/container/iso_gain_map.hpp"

namespace hyperdr {

struct BoxInfo {
  std::string type;
  std::uint64_t offset{};
  std::uint64_t size{};
  unsigned depth{};
};

struct HeifInspection {
  bool structurally_valid{false};
  bool has_heic_brand{false};
  bool has_tmap_brand{false};
  bool has_tmap_item{false};
  bool has_dimg_reference{false};
  bool has_altr_group{false};
  bool has_exif{false};
  bool has_xmp{false};
  bool has_data_information{false};
  bool gain_map_has_auxl_reference{false};
  // The auxiliary type URN the gain-map item declares, empty when the item is
  // not an auxiliary image at all. Reported rather than judged: Apple's own
  // captures declare a private URN here, so a fixed expected value belongs in a
  // writer's self-check, not in inspection.
  std::string gain_map_auxiliary_type;
  bool has_tmap_metadata{false};
  GainMapMetadata tmap_metadata{};
  std::uint32_t primary_item_id{};
  std::vector<BoxInfo> boxes;
  std::vector<std::string> errors;
};

[[nodiscard]] HeifInspection inspect_heif(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] std::string inspection_json(const HeifInspection& inspection);

}  // namespace hyperdr
