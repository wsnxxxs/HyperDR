#include "hyperdr/container/inspect.hpp"

#include "hyperdr/container/heif_reader.hpp"
#include "internal/bmff.hpp"
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

using container::Bytes;
using container::parse_iinf;
using container::parse_pitm;

bool container_type(std::string_view type) {
  static const std::set<std::string_view> types{"meta", "iprp", "ipco", "iref", "grpl"};
  return types.contains(type);
}

constexpr unsigned kMaxBoxDepth = heif_limits::box_depth;
constexpr std::size_t kMaxBoxCount = heif_limits::boxes;

void walk_boxes(std::span<const std::uint8_t> bytes, std::size_t begin, std::size_t end,
                unsigned depth, HeifInspection& result) {
  if (begin > end || end > bytes.size()) throw std::runtime_error("truncated HEIF container");
  if (depth > kMaxBoxDepth) throw std::runtime_error("HEIF box nesting is too deep");
  std::size_t count=result.boxes.size();
  for (const auto& box : container::bmff_boxes(std::span<const std::uint8_t>(bytes).subspan(begin,end-begin),begin,depth,count)) {
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
      const auto child_begin=box.offset + box.header + skip;
      const auto child_end=box.offset + box.size;
      if(child_begin>child_end)throw std::runtime_error("truncated HEIF container");
      if(child_begin<child_end)walk_boxes(bytes, child_begin, child_end, depth + 1, result);
    }
  }
}

}  // namespace

HeifInspection inspect_heif(std::span<const std::uint8_t> bytes) {
  HeifInspection result;
  try {
    std::size_t box_count=0;
    const auto top = container::bmff_boxes(bytes,0,0,box_count);
    const auto ftyp = std::find_if(top.begin(), top.end(), [](const auto& b) { return b.type == "ftyp"; });
    if (ftyp == top.end()) throw std::runtime_error("missing ftyp box");
    if (ftyp->size < ftyp->header + 8) throw std::runtime_error("truncated ftyp box");
    const auto note_brand = [&](std::size_t at) {
      const std::string brand(reinterpret_cast<const char*>(bytes.data() + at), 4);
      if (brand == "heic" || brand == "heix") result.has_heic_brand = true;
      if (brand == "tmap") result.has_tmap_brand = true;
    };
    // major_brand, then compatible_brands: the 4-byte minor_version between them
    // is a number, not a brand, and must not be matched against brand names.
    note_brand(ftyp->offset + ftyp->header);
    for (std::size_t p = ftyp->offset + ftyp->header + 8; p + 4 <= ftyp->offset + ftyp->size; p += 4) {
      note_brand(p);
    }
    if (std::any_of(top.begin(), top.end(), [](const auto& b) { return b.type == "meta"; })) {
      const auto file = read_heif(bytes);
      // The public diagnostic tree historically treats iinf and dinf as leaves.
      // Preserve its exact JSON while the reader also visits their children.
      std::optional<unsigned> leaf_depth;
      for (const auto& box : file.boxes) {
        if (leaf_depth && box.depth > *leaf_depth) continue;
        leaf_depth.reset();
        result.boxes.push_back(box);
        if (box.type == "iinf" || box.type == "dinf") leaf_depth = box.depth;
      }
      for (const auto& [id, item] : file.items) {
        (void)id;
        result.has_tmap_item |= item.type == "tmap";
        result.has_exif |= item.type == "Exif";
        result.has_xmp |= item.type == "mime";
      }
      result.primary_item_id = file.primary_item_id;
      result.has_data_information = file.has_data_information;
      if (const auto refs = file.tmap_references()) {
        if (refs->base_id != file.primary_item_id)
          throw std::runtime_error("tmap base is not the primary image");
        result.has_dimg_reference = true;
        for (const auto& group : file.groups) {
          if (group.type == "altr" && group.members ==
              std::vector<std::uint32_t>{refs->tmap_id, file.primary_item_id}) {
            if (result.has_altr_group) throw std::runtime_error("duplicate tmap altr group");
            result.has_altr_group = true;
          }
        }
        if (!result.has_altr_group) throw std::runtime_error("missing tmap altr group");
        const auto masters = file.targets(refs->gain_id, "auxl");
        result.gain_map_has_auxl_reference =
            std::find(masters.begin(), masters.end(), refs->base_id) != masters.end();
        result.gain_map_auxiliary_type = file.auxiliary_type(refs->gain_id);
        result.tmap_metadata = parse_tmap_payload(file.item_bytes(refs->tmap_id, 4096));
        result.has_tmap_metadata = true;
      }
    } else {
      // Structural inspection also supports fragments without a pict meta.
      walk_boxes(bytes, 0, bytes.size(), 0, result);
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
