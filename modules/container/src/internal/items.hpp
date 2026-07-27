#pragma once

// The item-description boxes both public entry points need to read: `iinf`
// (which items exist and what type each one is) and `pitm` (which one is the
// primary image). Inspection reads them; the tmap rewrite reads and rebuilds
// them, so the readers are shared and the rebuilders are not.

#include "internal/boxes.hpp"

#include <algorithm>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr::container {

struct ItemDesc { std::uint32_t id{}; std::string type; Bytes infe; };

inline std::vector<ItemDesc> parse_iinf(std::span<const std::uint8_t> box) {
  const auto version = fullbox_version(box);
  if (version > 1) throw std::runtime_error("unsupported iinf version");
  const std::size_t count_end = version == 0 ? 14 : 16;
  if (box.size() < count_end) throw std::runtime_error("truncated iinf");
  std::size_t p = count_end;
  const auto expected = version == 0 ? be16(box, 12) : be32(box, 12);
  std::vector<ItemDesc> items;
  while (p < box.size()) {
    const auto child = read_box(box, p, box.size());
    if (child.type == "infe") {
      if (child.size < 12) throw std::runtime_error("truncated infe");
      const auto v = box[child.offset + 8];
      std::uint32_t id = 0;
      std::size_t type_offset = 0;
      std::size_t name_offset = 0;
      if (v == 2) {
        if (child.size < 20) throw std::runtime_error("truncated infe v2");
        id = be16(box, child.offset + 12);
        type_offset = child.offset + 16;
        name_offset = child.offset + 20;
      } else if (v == 3) {
        if (child.size < 22) throw std::runtime_error("truncated infe v3");
        id = be32(box, child.offset + 12);
        type_offset = child.offset + 18;
        name_offset = child.offset + 22;
      } else {
        throw std::runtime_error("unsupported infe version");
      }
      const auto child_end = child.offset + child.size;
      if (std::find(box.begin() + static_cast<std::ptrdiff_t>(name_offset),
                    box.begin() + static_cast<std::ptrdiff_t>(child_end), 0) ==
          box.begin() + static_cast<std::ptrdiff_t>(child_end)) {
        throw std::runtime_error("infe item name is not null terminated");
      }
      std::string type(reinterpret_cast<const char*>(box.data() + type_offset), 4);
      if (id == 0) throw std::runtime_error("infe item id is zero");
      items.push_back({id, std::move(type), slice(box, child)});
    }
    p += child.size;
  }
  if (items.size() != expected) throw std::runtime_error("iinf entry count mismatch");
  return items;
}

inline std::uint32_t parse_pitm(std::span<const std::uint8_t> box) {
  return fullbox_version(box) == 0 ? be16(box, 12) : be32(box, 12);
}

}  // namespace hyperdr::container
