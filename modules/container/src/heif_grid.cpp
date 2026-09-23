#include "hyperdr/container/heif_grid.hpp"

#include "internal/boxes.hpp"
#include "internal/items.hpp"

#include <algorithm>
#include <limits>
#include <map>
#include <span>
#include <stdexcept>
#include <string_view>

namespace hyperdr {
namespace {

using container::Box;
using container::Bytes;
using container::be16;
using container::be32;
using container::children;
using container::fullbox_version;
using container::make_box;
using container::parse_iinf;
using container::parse_pitm;
using container::put16;
using container::put32;
using container::read_n;
using container::slice;

constexpr std::size_t kMaxTiles = 4096;
constexpr std::size_t kMaxItems = 8192;

void append(Bytes& dst, const Bytes& source) {
  dst.insert(dst.end(), source.begin(), source.end());
}

Box require_box(std::span<const std::uint8_t> bytes, std::size_t begin,
                std::size_t end, std::string_view type) {
  Box found{};
  for (const auto& box : children(bytes, begin, end)) {
    if (box.type != type) continue;
    if (found.size) throw std::runtime_error("duplicate HEIF " + std::string(type));
    found = box;
  }
  if (!found.size) throw std::runtime_error("missing HEIF " + std::string(type));
  return found;
}

struct Property {
  Bytes box;
  bool essential{};
};

struct Leaf {
  Bytes ftyp;
  Bytes hdlr;
  Bytes coded;
  std::vector<Property> properties;
};

Bytes primary_coded_data(std::span<const std::uint8_t> file,
                         std::span<const std::uint8_t> iloc, std::uint32_t primary,
                         const Box& mdat) {
  const auto version = fullbox_version(iloc);
  if (version > 2 || iloc.size() < 16) throw std::runtime_error("unsupported tile iloc");
  const unsigned offset_size = iloc[12] >> 4;
  const unsigned length_size = iloc[12] & 15;
  const unsigned base_size = iloc[13] >> 4;
  const unsigned index_size = version ? iloc[13] & 15 : 0;
  if ((offset_size != 4 && offset_size != 8) ||
      (length_size != 4 && length_size != 8) || base_size > 8 || index_size > 8) {
    throw std::runtime_error("unsupported tile iloc field width");
  }
  std::size_t p = 14;
  const auto count = read_n(iloc, p, version < 2 ? 2 : 4);
  if (count == 0 || count > 64) throw std::runtime_error("tile iloc item count is invalid");
  Bytes coded;
  bool found = false;
  for (std::uint64_t i = 0; i < count; ++i) {
    const auto id = read_n(iloc, p, version < 2 ? 2 : 4);
    const auto method = version ? read_n(iloc, p, 2) & 0x0FFFU : 0;
    const auto data_ref = read_n(iloc, p, 2);
    const auto base = read_n(iloc, p, base_size);
    const auto extents = read_n(iloc, p, 2);
    if (extents > 64) throw std::runtime_error("too many tile extents");
    if (id == primary) {
      if (found || method != 0 || data_ref != 0 || extents == 0) {
        throw std::runtime_error("unsupported primary tile location");
      }
      found = true;
    }
    for (std::uint64_t e = 0; e < extents; ++e) {
      if (index_size) (void)read_n(iloc, p, index_size);
      const auto offset = read_n(iloc, p, offset_size);
      const auto length = read_n(iloc, p, length_size);
      if (id != primary) continue;
      if (base > file.size() || offset > file.size() - base ||
          length > file.size() - base - offset) {
        throw std::runtime_error("tile extent is out of bounds");
      }
      const auto start = static_cast<std::size_t>(base + offset);
      const auto media_begin = mdat.offset + mdat.header;
      const auto media_end = mdat.offset + mdat.size;
      if (start < media_begin || start > media_end || length > media_end - start) {
        throw std::runtime_error("tile extent is outside mdat");
      }
      if (coded.size() > std::numeric_limits<std::uint32_t>::max() - length) {
        throw std::runtime_error("tile coded data is too large");
      }
      coded.insert(coded.end(), file.begin() + static_cast<std::ptrdiff_t>(start),
                   file.begin() + static_cast<std::ptrdiff_t>(start + length));
    }
  }
  if (!found || coded.empty() || p != iloc.size()) {
    throw std::runtime_error("primary tile data is missing or malformed");
  }
  return coded;
}

std::vector<Property> primary_properties(std::span<const std::uint8_t> iprp,
                                         std::uint32_t primary) {
  const auto ipco = require_box(iprp, 8, iprp.size(), "ipco");
  const auto ipma = require_box(iprp, 8, iprp.size(), "ipma");
  const auto props = children(iprp, ipco.offset + ipco.header, ipco.offset + ipco.size);
  if (props.empty() || props.size() > 0x7FFF) throw std::runtime_error("tile property count is invalid");
  const auto assoc = iprp.subspan(ipma.offset, ipma.size);
  const auto version = fullbox_version(assoc);
  if (version > 1 || assoc.size() < 16) throw std::runtime_error("unsupported tile ipma");
  const bool wide = (assoc[11] & 1U) != 0;
  const auto count = be32(assoc, 12);
  if (count == 0 || count > 64) throw std::runtime_error("tile ipma entry count is invalid");
  std::size_t p = 16;
  bool found = false;
  std::vector<Property> selected;
  for (std::uint32_t i = 0; i < count; ++i) {
    const auto id = read_n(assoc, p, version ? 4 : 2);
    const auto n = read_n(assoc, p, 1);
    if (id == primary && found) throw std::runtime_error("duplicate primary tile ipma");
    if (id == primary) found = true;
    for (std::uint64_t a = 0; a < n; ++a) {
      const auto raw = read_n(assoc, p, wide ? 2 : 1);
      if (id != primary) continue;
      const auto index = raw & (wide ? 0x7FFFU : 0x7FU);
      if (index == 0 || index > props.size()) throw std::runtime_error("invalid tile property index");
      selected.push_back({slice(iprp, props[index - 1]),
                          (raw & (wide ? 0x8000U : 0x80U)) != 0});
    }
  }
  if (!found || p != assoc.size()) throw std::runtime_error("primary tile ipma is missing or malformed");
  bool hvcc = false, ispe = false;
  for (const auto& prop : selected) {
    const auto type = std::string_view(reinterpret_cast<const char*>(prop.box.data() + 4), 4);
    hvcc |= type == "hvcC";
    ispe |= type == "ispe";
  }
  if (!hvcc || !ispe) throw std::runtime_error("tile lacks hvcC or ispe");
  return selected;
}

Leaf parse_leaf(const Bytes& file) {
  const auto bytes = std::span<const std::uint8_t>(file);
  const auto ftyp = require_box(bytes, 0, bytes.size(), "ftyp");
  const auto meta = require_box(bytes, 0, bytes.size(), "meta");
  const auto mdat = require_box(bytes, 0, bytes.size(), "mdat");
  const auto m = bytes.subspan(meta.offset, meta.size);
  const auto hdlr = require_box(m, 12, m.size(), "hdlr");
  const auto pitm = require_box(m, 12, m.size(), "pitm");
  const auto iinf = require_box(m, 12, m.size(), "iinf");
  const auto iloc = require_box(m, 12, m.size(), "iloc");
  const auto iprp = require_box(m, 12, m.size(), "iprp");
  const auto primary = parse_pitm(m.subspan(pitm.offset, pitm.size));
  bool is_hvc1 = false;
  for (const auto& item : parse_iinf(m.subspan(iinf.offset, iinf.size))) {
    if (item.id == primary) is_hvc1 = item.type == "hvc1";
  }
  if (!is_hvc1) throw std::runtime_error("tile primary is not hvc1");
  return {slice(bytes, ftyp), slice(m, hdlr),
          primary_coded_data(bytes, m.subspan(iloc.offset, iloc.size), primary, mdat),
          primary_properties(m.subspan(iprp.offset, iprp.size), primary)};
}

Bytes merged_ftyp(const Bytes& primary, const std::vector<Bytes>& sources) {
  if (primary.size() < 16 || (primary.size() - 16) % 4 != 0) {
    throw std::runtime_error("invalid primary tile ftyp");
  }
  Bytes payload(primary.begin() + 8, primary.begin() + 16);
  std::vector<std::string> brands;
  const auto add_brands = [&](const Bytes& source) {
    if (source.size() < 16 || (source.size() - 16) % 4 != 0) {
      throw std::runtime_error("invalid tile ftyp");
    }
    const auto add = [&](std::size_t offset) {
      std::string brand(reinterpret_cast<const char*>(source.data() + offset), 4);
      if (std::find(brands.begin(), brands.end(), brand) == brands.end()) {
        brands.push_back(std::move(brand));
      }
    };
    add(8);  // A source's major brand must remain compatible too.
    for (std::size_t p = 16; p < source.size(); p += 4) add(p);
  };
  add_brands(primary);
  for (const auto& source : sources) add_brands(source);
  for (const auto& brand : brands) payload.insert(payload.end(), brand.begin(), brand.end());
  return make_box("ftyp", payload);
}

Bytes make_infe(std::uint16_t id, std::string_view type, std::string_view name,
                bool hidden, std::string_view content_type = {}) {
  Bytes payload{2, 0, 0, static_cast<std::uint8_t>(hidden ? 1 : 0)};
  put16(payload, id);
  put16(payload, 0);
  payload.insert(payload.end(), type.begin(), type.end());
  payload.insert(payload.end(), name.begin(), name.end());
  payload.push_back(0);
  if (type == "mime") {
    payload.insert(payload.end(), content_type.begin(), content_type.end());
    payload.push_back(0);
    payload.push_back(0);  // Empty content encoding.
  }
  return make_box("infe", payload);
}

Bytes make_ispe(std::uint32_t width, std::uint32_t height) {
  Bytes payload{0, 0, 0, 0};
  put32(payload, width);
  put32(payload, height);
  return make_box("ispe", payload);
}

Bytes grid_payload(const EncodedHeifGrid& image) {
  Bytes payload{0, static_cast<std::uint8_t>(image.width > 65535 || image.height > 65535 ? 1 : 0),
                static_cast<std::uint8_t>(image.rows - 1),
                static_cast<std::uint8_t>(image.columns - 1)};
  if (payload[1]) {
    put32(payload, image.width);
    put32(payload, image.height);
  } else {
    put16(payload, static_cast<std::uint16_t>(image.width));
    put16(payload, static_cast<std::uint16_t>(image.height));
  }
  return payload;
}

struct Association {
  std::uint16_t index{};
  bool essential{};
};

struct Item {
  std::uint16_t id{};
  std::string_view type;
  std::string_view name;
  bool hidden{};
  Bytes data;
  std::vector<Association> properties;
  std::vector<std::uint16_t> derived_from;
  std::string_view content_type;
};

class PropertyPool {
 public:
  Association add(const Property& property) {
    const auto found = indexes_.find(property.box);
    if (found != indexes_.end()) return {found->second, property.essential};
    if (properties_.size() >= 0x7FFF) throw std::runtime_error("too many HEIF properties");
    const auto index = static_cast<std::uint16_t>(properties_.size() + 1);
    indexes_.emplace(property.box, index);
    properties_.push_back(property.box);
    return {index, property.essential};
  }

  [[nodiscard]] const std::vector<Bytes>& all() const { return properties_; }

 private:
  std::map<Bytes, std::uint16_t> indexes_;
  std::vector<Bytes> properties_;
};

Bytes make_iinf(const std::vector<Item>& items) {
  Bytes payload{1, 0, 0, 0};
  put32(payload, static_cast<std::uint32_t>(items.size()));
  for (const auto& item : items) {
    append(payload, make_infe(item.id, item.type, item.name, item.hidden,
                              item.content_type));
  }
  return make_box("iinf", payload);
}

Bytes make_iref(const std::vector<Item>& items, std::uint16_t primary) {
  Bytes payload{0, 0, 0, 0};
  for (const auto& item : items) {
    if (!item.derived_from.empty()) {
      Bytes reference;
      put16(reference, item.id);
      put16(reference, static_cast<std::uint16_t>(item.derived_from.size()));
      for (const auto id : item.derived_from) put16(reference, id);
      append(payload, make_box("dimg", reference));
    }
    if (item.type == "Exif" || item.type == "mime") {
      Bytes reference;
      put16(reference, item.id);
      put16(reference, 1);
      put16(reference, primary);
      append(payload, make_box("cdsc", reference));
    }
  }
  return make_box("iref", payload);
}

Bytes make_iprp(const std::vector<Item>& items, const PropertyPool& pool) {
  Bytes ipco_payload;
  for (const auto& property : pool.all()) append(ipco_payload, property);
  const auto ipco = make_box("ipco", ipco_payload);
  bool wide = false;
  std::uint32_t count = 0;
  for (const auto& item : items) {
    if (item.properties.empty()) continue;
    ++count;
    if (item.properties.size() > 255) throw std::runtime_error("too many item properties");
    for (const auto& property : item.properties) wide |= property.index > 127;
  }
  Bytes ipma_payload{0, 0, 0, static_cast<std::uint8_t>(wide ? 1 : 0)};
  put32(ipma_payload, count);
  for (const auto& item : items) {
    if (item.properties.empty()) continue;
    put16(ipma_payload, item.id);
    ipma_payload.push_back(static_cast<std::uint8_t>(item.properties.size()));
    for (const auto& property : item.properties) {
      if (wide) {
        put16(ipma_payload, static_cast<std::uint16_t>(
            property.index | (property.essential ? 0x8000U : 0U)));
      } else {
        ipma_payload.push_back(static_cast<std::uint8_t>(
            property.index | (property.essential ? 0x80U : 0U)));
      }
    }
  }
  Bytes payload;
  append(payload, ipco);
  append(payload, make_box("ipma", ipma_payload));
  return make_box("iprp", payload);
}

Bytes make_dinf() {
  const auto url = make_box("url ", Bytes{0, 0, 0, 1});
  Bytes dref{0, 0, 0, 0};
  put32(dref, 1);
  append(dref, url);
  return make_box("dinf", make_box("dref", dref));
}

Bytes make_iloc(const std::vector<Item>& items, std::uint64_t media_start) {
  // The bounded writer uses one 32-bit absolute extent per item. This is the
  // common libheif-compatible layout and keeps the tmap rewrite unchanged.
  Bytes payload{1, 0, 0, 0, 0x44, 0};
  put16(payload, static_cast<std::uint16_t>(items.size()));
  for (const auto& item : items) {
    if (media_start > std::numeric_limits<std::uint32_t>::max() ||
        item.data.size() > std::numeric_limits<std::uint32_t>::max() - media_start) {
      throw std::runtime_error("assembled HEIF exceeds 32-bit item offsets");
    }
    put16(payload, item.id);
    put16(payload, 0);  // construction_method 0
    put16(payload, 0);  // data_reference_index 0
    put16(payload, 1);  // extent_count
    put32(payload, static_cast<std::uint32_t>(media_start));
    put32(payload, static_cast<std::uint32_t>(item.data.size()));
    media_start += item.data.size();
  }
  return make_box("iloc", payload);
}

Bytes make_meta(const std::vector<Item>& items, const PropertyPool& properties,
                const Bytes& hdlr, std::uint16_t primary, std::uint64_t media_start) {
  Bytes payload{0, 0, 0, 0};
  append(payload, hdlr);
  append(payload, make_dinf());
  Bytes pitm{0, 0, 0, 0};
  put16(pitm, primary);
  append(payload, make_box("pitm", pitm));
  append(payload, make_iinf(items));
  append(payload, make_iloc(items, media_start));
  append(payload, make_iref(items, primary));
  append(payload, make_iprp(items, properties));
  return make_box("meta", payload);
}

}  // namespace

std::vector<std::uint8_t> assemble_heif_grids(
    const std::vector<EncodedHeifGrid>& images, std::size_t primary_index,
    const std::vector<std::uint8_t>& exif, const std::string& xmp) {
  if (images.empty() || images.size() > 2 || primary_index >= images.size()) {
    throw std::invalid_argument("HEIF assembly requires one or two images and a valid primary");
  }
  std::size_t tile_count = 0;
  for (const auto& image : images) {
    if (image.width == 0 || image.height == 0 || image.columns == 0 ||
        image.rows == 0 || image.columns > 256 || image.rows > 256 ||
        image.columns > kMaxTiles / image.rows ||
        image.tiles.size() != static_cast<std::size_t>(image.columns) * image.rows) {
      throw std::invalid_argument("invalid HEIF grid dimensions or tile count");
    }
    tile_count += image.tiles.size();
  }
  if (tile_count > kMaxTiles || tile_count + images.size() + 2 > kMaxItems) {
    throw std::invalid_argument("too many HEIF tile items");
  }

  std::vector<Item> items;
  PropertyPool pool;
  Bytes primary_ftyp, hdlr;
  std::vector<Bytes> tile_ftyps;
  tile_ftyps.reserve(tile_count);
  std::uint16_t primary = 0;
  for (std::size_t group = 0; group < images.size(); ++group) {
    const auto& image = images[group];
    std::vector<Leaf> leaves;
    leaves.reserve(image.tiles.size());
    for (std::size_t tile_index = 0; tile_index < image.tiles.size(); ++tile_index) {
      const auto& tile = image.tiles[tile_index];
      auto leaf = parse_leaf(tile);
      if (hdlr.empty()) hdlr = leaf.hdlr;
      if (group == primary_index && tile_index == 0) primary_ftyp = leaf.ftyp;
      tile_ftyps.push_back(leaf.ftyp);
      leaves.push_back(std::move(leaf));
    }
    const bool grid = leaves.size() > 1;
    const auto logical_id = static_cast<std::uint16_t>(items.size() + 1);
    if (group == primary_index) primary = logical_id;
    Item logical{logical_id, grid ? "grid" : "hvc1", grid ? "Grid" : "Image",
                 false, grid ? grid_payload(image) : std::move(leaves[0].coded)};
    if (grid) {
      logical.properties.push_back(pool.add({make_ispe(image.width, image.height), false}));
      for (const auto& property : leaves[0].properties) {
        const auto type = std::string_view(
            reinterpret_cast<const char*>(property.box.data() + 4), 4);
        if (type == "pixi" || type == "colr" || type == "clli") {
          logical.properties.push_back(pool.add(property));
        }
      }
    } else {
      for (const auto& property : leaves[0].properties) {
        logical.properties.push_back(pool.add(property));
      }
    }
    items.push_back(std::move(logical));
    if (!grid) continue;
    for (auto& leaf : leaves) {
      const auto id = static_cast<std::uint16_t>(items.size() + 1);
      Item tile_item{id, "hvc1", "Tile", true, std::move(leaf.coded)};
      for (const auto& property : leaf.properties) {
        tile_item.properties.push_back(pool.add(property));
      }
      items[static_cast<std::size_t>(logical_id - 1)].derived_from.push_back(id);
      items.push_back(std::move(tile_item));
    }
  }
  if (!exif.empty()) {
    Bytes data{0, 0, 0, 0};
    append(data, exif);
    items.push_back({static_cast<std::uint16_t>(items.size() + 1), "Exif", "Exif",
                     false, std::move(data)});
  }
  if (!xmp.empty()) {
    Bytes data(xmp.begin(), xmp.end());
    items.push_back({static_cast<std::uint16_t>(items.size() + 1), "mime", "XMP",
                     false, std::move(data), {}, {}, "application/rdf+xml"});
  }
  if (items.size() > kMaxItems) throw std::runtime_error("too many HEIF items");

  const auto ftyp = merged_ftyp(primary_ftyp, tile_ftyps);

  std::uint64_t media_size = 0;
  for (const auto& item : items) media_size += item.data.size();
  if (media_size > std::numeric_limits<std::uint32_t>::max() - 8U) {
    throw std::runtime_error("assembled HEIF media is too large");
  }
  auto meta = make_meta(items, pool, hdlr, primary, 0);
  const auto media_start = static_cast<std::uint64_t>(ftyp.size()) + meta.size() + 8U;
  meta = make_meta(items, pool, hdlr, primary, media_start);

  Bytes output;
  output.reserve(static_cast<std::size_t>(media_start + media_size));
  append(output, ftyp);
  append(output, meta);
  put32(output, static_cast<std::uint32_t>(media_size + 8U));
  output.insert(output.end(), {'m', 'd', 'a', 't'});
  for (const auto& item : items) append(output, item.data);
  return output;
}

}  // namespace hyperdr
