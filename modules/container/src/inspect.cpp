#include "hyperdr/container/inspect.hpp"

#include "hyperdr/container/heif_tmap.hpp"
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/foundation/json.hpp"
#include "internal/items.hpp"

#include <algorithm>
#include <set>
#include <span>
#include <stdexcept>
#include <string_view>

namespace hyperdr {
namespace {

using container::Box;
using container::Bytes;
using container::be32;
using container::children;
using container::fullbox_version;
using container::parse_iinf;
using container::parse_pitm;
using container::read_box;
using container::read_n;

bool container_type(std::string_view type) {
  static const std::set<std::string_view> types{"meta", "iprp", "ipco", "iref", "grpl"};
  return types.contains(type);
}

constexpr unsigned kMaxBoxDepth = 64;
constexpr std::size_t kMaxBoxCount = 16384;

void walk_boxes(std::span<const std::uint8_t> bytes, std::size_t begin, std::size_t end,
                unsigned depth, HeifInspection& result) {
  if (depth > kMaxBoxDepth) throw std::runtime_error("HEIF box nesting is too deep");
  for (const auto& box : children(bytes, begin, end)) {
    if (result.boxes.size() >= kMaxBoxCount) {
      throw std::runtime_error("HEIF contains too many boxes");
    }
    result.boxes.push_back({box.type, box.offset, box.size, depth});
    if (box.type == "tmap") result.has_tmap_item = true;
    if (box.type == "dimg") result.has_dimg_reference = true;
    if (box.type == "altr") result.has_altr_group = true;
    if (box.type == "Exif") result.has_exif = true;
    if (box.type == "mime") result.has_xmp = true;
    if (box.type == "pitm") result.primary_item_id = parse_pitm(bytes.subspan(box.offset, box.size));
    if (box.type == "iinf") {
      for (const auto& item : parse_iinf(bytes.subspan(box.offset, box.size))) {
        if (item.type == "tmap") result.has_tmap_item = true;
        if (item.type == "Exif") result.has_exif = true;
        if (item.type == "mime") result.has_xmp = true;
      }
    }
    if (container_type(box.type)) {
      const auto skip = (box.type == "meta" || box.type == "iref") ? 4U : 0U;
      walk_boxes(bytes, box.offset + box.header + skip, box.offset + box.size, depth + 1, result);
    }
  }
}

bool has_valid_tmap_altr(std::span<const std::uint8_t> bytes,
                         std::uint32_t tmap_id, std::uint32_t primary_id) {
  std::set<std::uint32_t> item_ids;
  std::set<std::uint32_t> group_ids;
  bool found = false;
  for (const auto& top : children(bytes, 0, bytes.size())) {
    if (top.type != "meta") continue;
    const auto meta = bytes.subspan(top.offset, top.size);
    const auto kids = children(meta, 12, meta.size());
    for (const auto& box : kids) {
      if (box.type == "iinf") {
        for (const auto& item : parse_iinf(meta.subspan(box.offset, box.size))) {
          item_ids.insert(item.id);
        }
      }
    }
    for (const auto& box : kids) {
      if (box.type != "grpl") continue;
      const auto grpl = meta.subspan(box.offset, box.size);
      for (const auto& group : children(grpl, 8, grpl.size())) {
        if (group.size < 20) throw std::runtime_error("truncated entity group");
        if (fullbox_version(grpl.subspan(group.offset, group.size)) != 0) {
          throw std::runtime_error("unsupported entity group version");
        }
        const auto group_id = be32(grpl, group.offset + 12);
        const auto count = be32(grpl, group.offset + 16);
        if (group_id == 0 || item_ids.contains(group_id) ||
            !group_ids.insert(group_id).second) {
          throw std::runtime_error("entity group id collides with an item or group");
        }
        if (count > (group.size - 20) / 4) {
          throw std::runtime_error("truncated entity group members");
        }
        if (group.type == "altr" && count == 2 &&
            be32(grpl, group.offset + 20) == tmap_id &&
            be32(grpl, group.offset + 24) == primary_id) {
          if (found) throw std::runtime_error("duplicate tmap altr group");
          found = true;
        }
      }
    }
  }
  return found;
}

bool meta_has_data_information(std::span<const std::uint8_t> bytes) {
  for (const auto& top : children(bytes, 0, bytes.size())) {
    if (top.type != "meta") continue;
    const auto meta = bytes.subspan(top.offset, top.size);
    for (const auto& box : children(meta, 12, meta.size())) {
      if (box.type == "dinf") return true;
    }
  }
  return false;
}

// Whether the gain-map item points at the base image as its master, and which
// auxiliary type it declares. macOS ImageIO exposed no ISO gain map for a file
// carrying neither (gate T2, 2026-08-09), which is why both are now reported.
void describe_gain_map_auxiliary(std::span<const std::uint8_t> bytes, std::uint32_t gain_id,
                                 std::uint32_t base_id, HeifInspection& result) {
  for (const auto& top : children(bytes, 0, bytes.size())) {
    if (top.type != "meta") continue;
    const auto meta = bytes.subspan(top.offset, top.size);
    for (const auto& box : children(meta, 12, meta.size())) {
      if (box.type == "iref") {
        const auto iref = meta.subspan(box.offset, box.size);
        const unsigned id_size = fullbox_version(iref) == 0 ? 2U : 4U;
        for (const auto& ref : children(iref, 12, iref.size())) {
          if (ref.type != "auxl") continue;
          std::size_t p = ref.offset + 8;
          const auto from = static_cast<std::uint32_t>(read_n(iref, p, id_size));
          const auto count = read_n(iref, p, 2);
          if (from != gain_id) continue;
          for (std::uint64_t i = 0; i < count; ++i) {
            if (static_cast<std::uint32_t>(read_n(iref, p, id_size)) == base_id) {
              result.gain_map_has_auxl_reference = true;
            }
          }
        }
      } else if (box.type == "iprp") {
        const auto iprp = meta.subspan(box.offset, box.size);
        Box ipco{}, ipma{};
        for (const auto& child : children(iprp, 8, iprp.size())) {
          if (child.type == "ipco") ipco = child;
          else if (child.type == "ipma") ipma = child;
        }
        if (ipco.size == 0 || ipma.size == 0) continue;
        const auto props = children(iprp, ipco.offset + ipco.header, ipco.offset + ipco.size);
        const auto ipma_view = iprp.subspan(ipma.offset, ipma.size);
        const auto version = fullbox_version(ipma_view);
        const auto flags = (static_cast<std::uint32_t>(ipma_view[9]) << 16) |
                           (static_cast<std::uint32_t>(ipma_view[10]) << 8) | ipma_view[11];
        std::size_t p = 12;
        const auto entries = be32(ipma_view, p); p += 4;
        for (std::uint32_t entry = 0; entry < entries; ++entry) {
          const auto id = static_cast<std::uint32_t>(read_n(ipma_view, p, version < 1 ? 2 : 4));
          if (p >= ipma_view.size()) throw std::runtime_error("truncated ipma");
          const auto n = ipma_view[p++];
          for (unsigned a = 0; a < n; ++a) {
            const std::uint64_t raw = read_n(ipma_view, p, (flags & 1U) ? 2 : 1);
            const std::size_t index =
                static_cast<std::size_t>(raw & ((flags & 1U) ? 0x7FFFU : 0x7FU));
            if (id != gain_id || index == 0 || index > props.size()) continue;
            const auto& property = props[index - 1];
            if (property.type != "auxC" || property.size <= property.header + 4) continue;
            const auto start = property.offset + property.header + 4;
            const auto stop = property.offset + property.size;
            const auto* text = reinterpret_cast<const char*>(iprp.data() + start);
            const auto length = static_cast<std::size_t>(stop - start);
            result.gain_map_auxiliary_type.assign(text, std::find(text, text + length, '\0'));
          }
        }
      }
    }
  }
}

}  // namespace

HeifInspection inspect_heif(const Bytes& bytes) {
  HeifInspection result;
  try {
    const auto top = children(bytes, 0, bytes.size());
    const auto ftyp = std::find_if(top.begin(), top.end(), [](const Box& b) { return b.type == "ftyp"; });
    if (ftyp == top.end()) throw std::runtime_error("missing ftyp box");
    if (ftyp->size < 16) throw std::runtime_error("truncated ftyp box");
    const auto note_brand = [&](std::size_t at) {
      const std::string brand(reinterpret_cast<const char*>(bytes.data() + at), 4);
      if (brand == "heic" || brand == "heix") result.has_heic_brand = true;
      if (brand == "tmap") result.has_tmap_brand = true;
    };
    // major_brand, then compatible_brands: the 4-byte minor_version between them
    // is a number, not a brand, and must not be matched against brand names.
    note_brand(ftyp->offset + 8);
    for (std::size_t p = ftyp->offset + 16; p + 4 <= ftyp->offset + ftyp->size; p += 4) {
      note_brand(p);
    }
    walk_boxes(bytes, 0, bytes.size(), 0, result);
    result.has_data_information = meta_has_data_information(bytes);
    // Grid images also use dimg, so bind both checks to the actual tmap item
    // instead of accepting any unrelated dimg/altr box.
    result.has_dimg_reference = false;
    result.has_altr_group = false;
    if (result.has_tmap_item) {
      const auto references = find_tmap_references(bytes);
      if (references.base_id != result.primary_item_id) {
        throw std::runtime_error("tmap base is not the primary image");
      }
      result.has_dimg_reference = true;
      result.has_altr_group =
          has_valid_tmap_altr(bytes, references.tmap_id, result.primary_item_id);
      if (!result.has_altr_group) throw std::runtime_error("missing tmap altr group");
      describe_gain_map_auxiliary(bytes, references.gain_id, references.base_id, result);
      result.tmap_metadata = parse_tmap_payload(extract_tmap_payload(bytes));
      result.has_tmap_metadata = true;
    }
    result.structurally_valid = true;
  } catch (const std::exception& e) { result.errors.push_back(e.what()); }
  return result;
}

std::string inspection_json(const HeifInspection& inspection) {
  json::Writer writer;
  writer.begin_object()
      .member("structurally_valid", inspection.structurally_valid)
      .member("heic_brand", inspection.has_heic_brand)
      .member("tmap_brand", inspection.has_tmap_brand)
      .member("tmap_item", inspection.has_tmap_item)
      .member("dimg", inspection.has_dimg_reference)
      .member("altr", inspection.has_altr_group)
      .member("exif", inspection.has_exif)
      .member("xmp", inspection.has_xmp)
      .member("dinf", inspection.has_data_information)
      .member("gain_map_auxl", inspection.gain_map_has_auxl_reference)
      .member("gain_map_auxiliary_type", inspection.gain_map_auxiliary_type)
      .member("tmap_metadata_present", inspection.has_tmap_metadata)
      .member("primary_item", inspection.primary_item_id)
      ;
  if (inspection.has_tmap_metadata) {
    writer.begin_object("tmap_metadata")
        .member("minimum_version", inspection.tmap_metadata.minimum_version)
        .member("writer_version", inspection.tmap_metadata.writer_version)
        .member("flags", inspection.tmap_metadata.flags)
        .member("use_base_color_space", inspection.tmap_metadata.use_base_color_space)
        .member("backward_direction", inspection.tmap_metadata.backward_direction)
        .member("common_denominator", inspection.tmap_metadata.common_denominator);
    const auto write_rational = [&](std::string_view key, const Rational& value) {
      writer.begin_object(key)
          .member("numerator", value.numerator)
          .member("denominator", value.denominator)
          .end_object();
    };
    write_rational("base_headroom", inspection.tmap_metadata.base_headroom);
    write_rational("alternate_headroom", inspection.tmap_metadata.alternate_headroom);
    const auto channel_count =
        gain_map_channel_count(inspection.tmap_metadata);
    if (channel_count == 1) {
      const auto channel = gain_map_channel(inspection.tmap_metadata, 0);
      write_rational("gain_min", channel.gain_min);
      write_rational("gain_max", channel.gain_max);
      write_rational("gamma", channel.gamma);
      write_rational("base_offset", channel.base_offset);
      write_rational("alternate_offset", channel.alternate_offset);
    } else {
      writer.begin_array("channels");
      for (std::size_t index = 0; index < channel_count; ++index) {
        const auto channel = gain_map_channel(inspection.tmap_metadata, index);
        writer.begin_object();
        write_rational("gain_min", channel.gain_min);
        write_rational("gain_max", channel.gain_max);
        write_rational("gamma", channel.gamma);
        write_rational("base_offset", channel.base_offset);
        write_rational("alternate_offset", channel.alternate_offset);
        writer.end_object();
      }
      writer.end_array();
    }
    writer.end_object();
  }
  writer.begin_array("errors");
  for (const auto& error : inspection.errors) writer.element(error);
  writer.end_array().begin_array("boxes");
  for (const auto& box : inspection.boxes) {
    writer.begin_object()
        .member("type", box.type)
        .member("offset", box.offset)
        .member("size", box.size)
        .member("depth", box.depth)
        .end_object();
  }
  return writer.end_array().end_object().take();
}

}  // namespace hyperdr
