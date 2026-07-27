#include "hyperdr/container/heif_tmap.hpp"

#include "internal/items.hpp"

#include <algorithm>
#include <limits>
#include <optional>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <string_view>

namespace hyperdr {
namespace {

using container::Box;
using container::ItemDesc;
using container::Bytes;
using container::be16;
using container::be32;
using container::be64;
using container::children;
using container::fullbox_version;
using container::parse_iinf;
using container::parse_pitm;
using container::make_box;
using container::put16;
using container::put32;
using container::put64;
using container::read_box;
using container::read_n;
using container::set32;
using container::slice;

Bytes make_infe(std::uint16_t id, std::string_view type, std::string_view name, bool hidden) {
  Bytes payload{2, 0, 0, static_cast<std::uint8_t>(hidden ? 1 : 0)};
  put16(payload, id); put16(payload, 0);
  payload.insert(payload.end(), type.begin(), type.end());
  payload.insert(payload.end(), name.begin(), name.end()); payload.push_back(0);
  return make_box("infe", payload);
}

Bytes rebuild_iinf(std::span<const std::uint8_t> original, std::uint16_t gain_id, std::uint16_t tmap_id) {
  auto items = parse_iinf(original);
  Bytes payload{1, 0, 0, 0};
  put32(payload, static_cast<std::uint32_t>(items.size() + 1));
  for (auto& item : items) {
    if (item.id == gain_id && item.infe.size() >= 12) item.infe[11] |= 1;  // hidden_item flag.
    payload.insert(payload.end(), item.infe.begin(), item.infe.end());
  }
  const auto tmap = make_infe(tmap_id, "tmap", "ToneMappedImage", false);
  payload.insert(payload.end(), tmap.begin(), tmap.end());
  return make_box("iinf", payload);
}

struct Extent { std::uint64_t offset{}; std::uint64_t length{}; };
struct Location { std::uint32_t id{}; std::uint16_t construction_method{}; std::uint16_t data_ref{}; std::uint64_t base{}; std::vector<Extent> extents; };

constexpr std::uint64_t kMaxIlocLocations = 4096;
constexpr std::uint64_t kMaxIlocExtents = 4096;

std::vector<Location> parse_iloc(std::span<const std::uint8_t> box) {
  const auto version = fullbox_version(box);
  std::size_t p = 12;
  if (p + 2 > box.size()) throw std::runtime_error("truncated iloc");
  const unsigned offset_size = box[p] >> 4, length_size = box[p] & 15;
  const unsigned base_size = box[p + 1] >> 4, index_size = (version == 1 || version == 2) ? box[p + 1] & 15 : 0;
  p += 2;
  const auto count = version < 2 ? read_n(box, p, 2) : read_n(box, p, 4);
  if (count > kMaxIlocLocations) throw std::runtime_error("iloc has too many locations");
  std::vector<Location> result;
  result.reserve(static_cast<std::size_t>(count));
  std::uint64_t total_extents = 0;
  for (std::uint64_t i = 0; i < count; ++i) {
    Location loc;
    loc.id = static_cast<std::uint32_t>(read_n(box, p, version < 2 ? 2 : 4));
    if (version == 1 || version == 2) {
      loc.construction_method = static_cast<std::uint16_t>(read_n(box, p, 2) & 0x0FFFU);
      if (loc.construction_method > 1) throw std::runtime_error("unsupported iloc construction method");
    }
    loc.data_ref = static_cast<std::uint16_t>(read_n(box, p, 2));
    loc.base = read_n(box, p, base_size);
    const auto ext_count = read_n(box, p, 2);
    if (ext_count > kMaxIlocExtents || total_extents > kMaxIlocExtents - ext_count) {
      throw std::runtime_error("iloc has too many extents");
    }
    if (ext_count != 0 && (offset_size == 0 || length_size == 0)) {
      throw std::runtime_error("iloc extent fields must have nonzero widths");
    }
    total_extents += ext_count;
    loc.extents.reserve(static_cast<std::size_t>(ext_count));
    for (std::uint64_t e = 0; e < ext_count; ++e) {
      if (index_size) (void)read_n(box, p, index_size);
      loc.extents.push_back({read_n(box, p, offset_size), read_n(box, p, length_size)});
    }
    result.push_back(std::move(loc));
  }
  if (p != box.size()) throw std::runtime_error("unexpected iloc trailing bytes");
  return result;
}

Bytes rebuild_iloc(std::span<const std::uint8_t> original, std::uint32_t tmap_id,
                   std::uint64_t payload_offset, std::uint64_t payload_length,
                   std::uint64_t extent_shift) {
  auto locations = parse_iloc(original);
  for (auto& loc : locations) {
    // Fold base offsets into the extents and apply the shift caused by the enlarged
    // ftyp box. Construction method 1 (idat) extents are idat-relative and unshifted.
    const std::uint64_t applied = loc.construction_method == 0 ? extent_shift : 0;
    if (loc.base > std::numeric_limits<std::uint64_t>::max() - applied) {
      throw std::runtime_error("iloc base offset overflows");
    }
    const std::uint64_t shift = loc.base + applied;
    for (auto& extent : loc.extents) {
      if (extent.offset > std::numeric_limits<std::uint64_t>::max() - shift) {
        throw std::runtime_error("iloc extent offset overflows");
      }
      extent.offset += shift;
    }
    loc.base = 0;
  }
  locations.push_back({tmap_id, 0, 0, 0, {{payload_offset, payload_length}}});

  bool narrow = true;
  for (const auto& loc : locations) {
    if (loc.id > 0xFFFFU) narrow = false;
    for (const auto& extent : loc.extents) {
      if (extent.offset > std::numeric_limits<std::uint32_t>::max() ||
          extent.length > std::numeric_limits<std::uint32_t>::max()) narrow = false;
    }
  }

  Bytes payload;
  if (narrow) {
    // Version 1 with 32-bit offsets: the most widely parsed iloc layout that still
    // carries construction_method.
    payload = {1, 0, 0, 0, 0x44, 0x00};
    put16(payload, static_cast<std::uint16_t>(locations.size()));
    for (const auto& loc : locations) {
      put16(payload, static_cast<std::uint16_t>(loc.id)); put16(payload, loc.construction_method);
      put16(payload, loc.data_ref); put16(payload, static_cast<std::uint16_t>(loc.extents.size()));
      for (const auto& extent : loc.extents) {
        put32(payload, static_cast<std::uint32_t>(extent.offset));
        put32(payload, static_cast<std::uint32_t>(extent.length));
      }
    }
  } else {
    payload = {2, 0, 0, 0, 0x88, 0x00};  // v2, 64-bit offsets and lengths.
    put32(payload, static_cast<std::uint32_t>(locations.size()));
    for (const auto& loc : locations) {
      put32(payload, loc.id); put16(payload, loc.construction_method); put16(payload, loc.data_ref); put16(payload, static_cast<std::uint16_t>(loc.extents.size()));
      for (const auto& extent : loc.extents) { put64(payload, extent.offset); put64(payload, extent.length); }
    }
  }
  return make_box("iloc", payload);
}

struct Association { bool essential{}; std::uint16_t index{}; };

std::vector<Association> primary_associations(std::span<const std::uint8_t> ipma, std::uint32_t primary_id) {
  const auto version = fullbox_version(ipma);
  const auto flags = (static_cast<std::uint32_t>(ipma[9]) << 16) | (static_cast<std::uint32_t>(ipma[10]) << 8) | ipma[11];
  std::size_t p = 12;
  const auto count = be32(ipma, p); p += 4;
  for (std::uint32_t i = 0; i < count; ++i) {
    const auto id = static_cast<std::uint32_t>(read_n(ipma, p, version < 1 ? 2 : 4));
    if (p >= ipma.size()) throw std::runtime_error("truncated ipma");
    const auto n = ipma[p++];
    std::vector<Association> associations;
    for (unsigned a = 0; a < n; ++a) {
      const auto raw = read_n(ipma, p, (flags & 1U) ? 2 : 1);
      associations.push_back({(raw & ((flags & 1U) ? 0x8000U : 0x80U)) != 0,
                              static_cast<std::uint16_t>(raw & ((flags & 1U) ? 0x7FFFU : 0x7FU))});
    }
    if (id == primary_id) return associations;
  }
  throw std::runtime_error("primary item has no ipma association");
}

Bytes append_ipma_entry(Bytes ipma, std::uint32_t item_id, const std::vector<Association>& associations) {
  const auto version = fullbox_version(ipma);
  const auto flags = (static_cast<std::uint32_t>(ipma[9]) << 16) | (static_cast<std::uint32_t>(ipma[10]) << 8) | ipma[11];
  set32(ipma, 12, be32(ipma, 12) + 1);
  if (version < 1) put16(ipma, static_cast<std::uint16_t>(item_id)); else put32(ipma, item_id);
  ipma.push_back(static_cast<std::uint8_t>(associations.size()));
  for (const auto& a : associations) {
    if (flags & 1U) put16(ipma, static_cast<std::uint16_t>((a.essential ? 0x8000U : 0U) | a.index));
    else ipma.push_back(static_cast<std::uint8_t>((a.essential ? 0x80U : 0U) | a.index));
  }
  set32(ipma, 0, static_cast<std::uint32_t>(ipma.size()));
  return ipma;
}

Bytes rebuild_iprp(std::span<const std::uint8_t> original, std::uint32_t primary_id, std::uint32_t tmap_id) {
  const auto kids = children(original, 8, original.size());
  Box ipco{}, ipma{};
  for (const auto& b : kids) { if (b.type == "ipco") ipco = b; else if (b.type == "ipma") ipma = b; }
  if (ipco.size == 0 || ipma.size == 0) throw std::runtime_error("iprp lacks ipco/ipma");
  const auto props = children(original, ipco.offset + ipco.header, ipco.offset + ipco.size);
  const auto all = primary_associations(original.subspan(ipma.offset, ipma.size), primary_id);
  std::vector<Association> selected;
  for (const auto& assoc : all) {
    if (assoc.index == 0 || assoc.index > props.size()) continue;
    const auto& type = props[assoc.index - 1].type;
    if (type == "ispe" || type == "pixi" || type == "colr" || type == "clli") selected.push_back(assoc);
  }
  if (std::none_of(selected.begin(), selected.end(), [&](const Association& a) { return props[a.index - 1].type == "ispe"; }))
    throw std::runtime_error("primary item lacks mandatory ispe property");
  Bytes payload;
  for (const auto& b : kids) {
    auto data = slice(original, b);
    if (b.type == "ipma") data = append_ipma_entry(std::move(data), tmap_id, selected);
    payload.insert(payload.end(), data.begin(), data.end());
  }
  return make_box("iprp", payload);
}

Bytes rebuild_iref(std::optional<std::span<const std::uint8_t>> original,
                   std::uint16_t tmap_id, std::uint16_t base_id, std::uint16_t gain_id) {
  std::uint8_t version = 0;
  Bytes payload;
  if (original) { version = static_cast<std::uint8_t>(fullbox_version(*original)); payload.assign(original->begin() + 8, original->end()); }
  else payload = {0, 0, 0, 0};
  Bytes ref;
  if (version == 0) { put16(ref, tmap_id); put16(ref, 2); put16(ref, base_id); put16(ref, gain_id); }
  else { put32(ref, tmap_id); put16(ref, 2); put32(ref, base_id); put32(ref, gain_id); }
  const auto dimg = make_box("dimg", ref);
  payload.insert(payload.end(), dimg.begin(), dimg.end());
  return make_box("iref", payload);
}

Bytes rebuild_grpl(std::optional<std::span<const std::uint8_t>> original,
                   std::uint32_t group_id, std::uint32_t tmap_id,
                   std::uint32_t primary_id) {
  Bytes payload;
  if (original) payload.assign(original->begin() + 8, original->end());
  Bytes altr{0, 0, 0, 0};
  put32(altr, group_id); put32(altr, 2); put32(altr, tmap_id); put32(altr, primary_id);
  const auto group = make_box("altr", altr);
  payload.insert(payload.end(), group.begin(), group.end());
  return make_box("grpl", payload);
}

Bytes build_meta(std::span<const std::uint8_t> original, std::uint16_t primary_id,
                 std::uint16_t gain_id, std::uint16_t tmap_id,
                 std::uint64_t payload_offset, std::uint64_t payload_length,
                 std::uint64_t extent_shift) {
  const auto kids = children(original, 12, original.size());
  std::optional<Box> old_iref;
  std::optional<Box> old_grpl;
  Bytes payload{0, 0, 0, 0};
  for (const auto& b : kids) {
    if (b.type == "iref") { old_iref = b; continue; }
    if (b.type == "grpl") {
      if (old_grpl) throw std::runtime_error("multiple grpl boxes are unsupported");
      old_grpl = b;
      continue;
    }
    Bytes data;
    const auto view = original.subspan(b.offset, b.size);
    if (b.type == "iinf") data = rebuild_iinf(view, gain_id, tmap_id);
    else if (b.type == "iloc") data = rebuild_iloc(view, tmap_id, payload_offset, payload_length, extent_shift);
    else if (b.type == "iprp") data = rebuild_iprp(view, primary_id, tmap_id);
    else data.assign(view.begin(), view.end());
    payload.insert(payload.end(), data.begin(), data.end());
  }
  const auto iref = rebuild_iref(old_iref ? std::optional(original.subspan(old_iref->offset, old_iref->size)) : std::nullopt,
                                 tmap_id, primary_id, gain_id);
  payload.insert(payload.end(), iref.begin(), iref.end());
  // Preserve existing entity groups and choose an unused group ID. Existing
  // group IDs must not collide with the newly allocated tmap item ID.
  std::set<std::uint32_t> existing_group_ids;
  if (old_grpl) {
    const auto old = original.subspan(old_grpl->offset, old_grpl->size);
    for (const auto& group : children(old, 8, old.size())) {
      if (group.size < 16) throw std::runtime_error("truncated existing entity group");
      const auto id = be32(old, group.offset + 12);
      if (id == tmap_id) throw std::runtime_error("new tmap id collides with existing group");
      existing_group_ids.insert(id);
    }
  }
  std::uint32_t group_id = static_cast<std::uint32_t>(tmap_id) + 1U;
  while (existing_group_ids.contains(group_id)) {
    if (group_id == std::numeric_limits<std::uint32_t>::max()) {
      throw std::runtime_error("no free entity group id");
    }
    ++group_id;
  }
  const auto grpl = rebuild_grpl(
      old_grpl ? std::optional(original.subspan(old_grpl->offset, old_grpl->size))
               : std::nullopt,
      group_id, tmap_id, primary_id);
  payload.insert(payload.end(), grpl.begin(), grpl.end());
  return make_box("meta", payload);
}

}  // namespace

Bytes extract_tmap_payload(const Bytes& bytes) {
  const auto top = children(bytes, 0, bytes.size());
  const auto meta_it = std::find_if(top.begin(), top.end(),
                                    [](const Box& b) { return b.type == "meta"; });
  if (meta_it == top.end()) throw std::runtime_error("missing meta box");
  const auto meta_view = std::span<const std::uint8_t>(bytes).subspan(meta_it->offset,
                                                                      meta_it->size);
  const auto kids = children(meta_view, 12, meta_view.size());
  std::uint32_t tmap_id = 0;
  std::optional<Box> iloc_box;
  std::optional<Box> idat_box;
  for (const auto& box : kids) {
    if (box.type == "iinf") {
      for (const auto& item : parse_iinf(meta_view.subspan(box.offset, box.size))) {
        if (item.type == "tmap") {
          if (tmap_id != 0) throw std::runtime_error("multiple tmap items");
          tmap_id = item.id;
        }
      }
    } else if (box.type == "iloc") {
      iloc_box = box;
    } else if (box.type == "idat") {
      idat_box = box;
    }
  }
  if (tmap_id == 0 || !iloc_box) throw std::runtime_error("missing tmap iloc");
  const auto locations =
      parse_iloc(meta_view.subspan(iloc_box->offset, iloc_box->size));
  const auto location = std::find_if(locations.begin(), locations.end(),
                                     [&](const Location& loc) { return loc.id == tmap_id; });
  if (location == locations.end() || location->extents.empty()) {
    throw std::runtime_error("tmap item has no extents");
  }
  if (location->data_ref != 0) throw std::runtime_error("external tmap data reference is unsupported");

  Bytes payload;
  for (const auto& extent : location->extents) {
    if (extent.offset > std::numeric_limits<std::uint64_t>::max() - location->base) {
      throw std::runtime_error("tmap extent offset overflows");
    }
    std::uint64_t offset = location->base + extent.offset;
    if (location->construction_method == 1) {
      if (!idat_box) throw std::runtime_error("tmap uses idat but idat is missing");
      const std::uint64_t idat_offset = meta_it->offset + idat_box->offset + idat_box->header;
      if (offset > std::numeric_limits<std::uint64_t>::max() - idat_offset) {
        throw std::runtime_error("tmap idat offset overflows");
      }
      offset += idat_offset;
    }
    if (offset > bytes.size() || extent.length > bytes.size() - offset) {
      throw std::runtime_error("tmap extent is out of bounds");
    }
    if (extent.length > 1024U * 1024U || payload.size() > 1024U * 1024U - extent.length) {
      throw std::runtime_error("tmap payload is unreasonably large");
    }
    payload.insert(payload.end(),
                   bytes.begin() + static_cast<std::ptrdiff_t>(offset),
                   bytes.begin() + static_cast<std::ptrdiff_t>(offset + extent.length));
  }
  // Semantic validation is the gain-map layer's business: every caller parses
  // this payload immediately, and doing it here as well would make the
  // container module depend upward on ISO 21496-1.
  return payload;
}

TmapReferences find_tmap_references(const Bytes& bytes) {
  for (const auto& box : children(bytes, 0, bytes.size())) {
    if (box.type != "meta") continue;
    const auto meta_view = std::span<const std::uint8_t>(bytes).subspan(box.offset, box.size);
    const auto kids = children(meta_view, 12, meta_view.size());
    std::uint32_t tmap_id = 0;
    for (const auto& b : kids) {
      if (b.type != "iinf") continue;
      for (const auto& item : parse_iinf(meta_view.subspan(b.offset, b.size)))
        if (item.type == "tmap") tmap_id = item.id;
    }
    if (tmap_id == 0) continue;
    for (const auto& b : kids) {
      if (b.type != "iref") continue;
      const auto view = meta_view.subspan(b.offset, b.size);
      const unsigned id_size = fullbox_version(view) == 0 ? 2U : 4U;
      for (const auto& ref : children(view, 12, view.size())) {
        if (ref.type != "dimg") continue;
        std::size_t p = ref.offset + 8;
        const auto from = static_cast<std::uint32_t>(read_n(view, p, id_size));
        const auto count = read_n(view, p, 2);
        if (from != tmap_id) continue;
        if (count != 2) throw std::runtime_error("tmap dimg must contain exactly [base, gain]");
        const auto base = static_cast<std::uint32_t>(read_n(view, p, id_size));
        const auto gain = static_cast<std::uint32_t>(read_n(view, p, id_size));
        if (base == 0 || gain == 0 || base == gain || base == tmap_id || gain == tmap_id) {
          throw std::runtime_error("invalid tmap dimg item ids");
        }
        return {tmap_id, base, gain};
      }
    }
  }
  throw std::runtime_error("file has no tmap item with dimg references");
}

Bytes add_tmap_to_two_image_heif(const Bytes& source, const Bytes& tmap_payload) {
  const auto top = children(source, 0, source.size());
  const auto ftyp_it = std::find_if(top.begin(), top.end(), [](const Box& b) { return b.type == "ftyp"; });
  const auto meta_it = std::find_if(top.begin(), top.end(), [](const Box& b) { return b.type == "meta"; });
  if (ftyp_it == top.end() || meta_it == top.end()) throw std::runtime_error("libheif output lacks ftyp/meta");

  // Append the tmap compatible brand instead of overwriting an existing one; all
  // absolute item offsets after ftyp are shifted by the growth and rewritten below.
  bool tmap_brand = false;
  for (std::size_t p = ftyp_it->offset + 16; p + 4 <= ftyp_it->offset + ftyp_it->size; p += 4) {
    if (std::string_view(reinterpret_cast<const char*>(source.data() + p), 4) == "tmap") tmap_brand = true;
  }
  Bytes new_ftyp(source.begin() + static_cast<std::ptrdiff_t>(ftyp_it->offset + 8),
                 source.begin() + static_cast<std::ptrdiff_t>(ftyp_it->offset + ftyp_it->size));
  if (!tmap_brand) new_ftyp.insert(new_ftyp.end(), {'t', 'm', 'a', 'p'});
  new_ftyp = make_box("ftyp", new_ftyp);
  const std::uint64_t extent_shift = new_ftyp.size() - ftyp_it->size;

  const auto meta_view = std::span<const std::uint8_t>(source).subspan(meta_it->offset, meta_it->size);
  const auto meta_kids = children(meta_view, 12, meta_view.size());
  const auto pitm = std::find_if(meta_kids.begin(), meta_kids.end(), [](const Box& b) { return b.type == "pitm"; });
  const auto iinf = std::find_if(meta_kids.begin(), meta_kids.end(), [](const Box& b) { return b.type == "iinf"; });
  if (pitm == meta_kids.end() || iinf == meta_kids.end()) throw std::runtime_error("meta lacks pitm/iinf");
  const auto primary_id = static_cast<std::uint16_t>(parse_pitm(meta_view.subspan(pitm->offset, pitm->size)));
  const auto items = parse_iinf(meta_view.subspan(iinf->offset, iinf->size));
  std::uint16_t gain_id = 0, max_id = 0;
  for (const auto& item : items) {
    max_id = std::max(max_id, static_cast<std::uint16_t>(item.id));
    const bool hidden = item.infe.size() >= 12 && (item.infe[11] & 1U) != 0;
    // The Gain Map is encoded first, so it is the lowest-numbered visible HEVC item
    // that is not the primary image; grid tile items are hidden by libheif.
    if ((item.type == "hvc1" || item.type == "hev1") && item.id != primary_id &&
        !hidden && gain_id == 0) gain_id = static_cast<std::uint16_t>(item.id);
  }
  if (gain_id == 0 || max_id == std::numeric_limits<std::uint16_t>::max()) throw std::runtime_error("expected a second HEVC image item");
  const auto tmap_id = static_cast<std::uint16_t>(max_id + 1);

  auto placeholder = build_meta(meta_view, primary_id, gain_id, tmap_id, 0, tmap_payload.size(), extent_shift);
  const auto payload_offset = extent_shift + static_cast<std::uint64_t>(source.size()) + placeholder.size() + 8;
  auto new_meta = build_meta(meta_view, primary_id, gain_id, tmap_id, payload_offset, tmap_payload.size(), extent_shift);
  if (new_meta.size() != placeholder.size()) throw std::runtime_error("unstable rebuilt meta size");

  Bytes output;
  output.reserve(source.size() + extent_shift + new_meta.size() + tmap_payload.size() + 8);
  for (const auto& box : top) {
    if (box.type == "ftyp") {
      output.insert(output.end(), new_ftyp.begin(), new_ftyp.end());
      continue;
    }
    const auto begin = source.begin() + static_cast<std::ptrdiff_t>(box.offset);
    const auto box_start = output.size();
    output.insert(output.end(), begin, begin + static_cast<std::ptrdiff_t>(box.size));
    if (box.type == "meta") std::copy_n("free", 4, output.begin() + static_cast<std::ptrdiff_t>(box_start + 4));
  }
  output.insert(output.end(), new_meta.begin(), new_meta.end());
  const auto tmap_mdat = make_box("mdat", tmap_payload);
  output.insert(output.end(), tmap_mdat.begin(), tmap_mdat.end());
  return output;
}

}  // namespace hyperdr
