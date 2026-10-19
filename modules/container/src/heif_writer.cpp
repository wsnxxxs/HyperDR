#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include "internal/boxes.hpp"
#include "internal/hevc_bits.hpp"
#include "internal/tmap_write.hpp"
#include "internal/write_limits.hpp"
#include <algorithm>
#include <array>
#include <limits>
#include <map>
#include <string_view>

namespace hyperdr {
namespace {
using container::Bytes;
using container::make_box;
using container::put16;
using container::put32;
constexpr std::size_t kMaxTiles = container::kHeifMaxTiles;
constexpr std::size_t kMaxItems = container::kHeifMaxItems;
constexpr std::size_t kMetadataLimit = 4U * 1024 * 1024;
constexpr std::uint64_t kFileLimit = std::numeric_limits<std::uint32_t>::max();
struct Grid { std::uint32_t width, height, columns, rows; };
struct Property { Bytes box; bool essential{}; };
void append(Bytes& dst, const Bytes& source) {
  (void)container::bounded_heif_add(dst.size(),source.size());
  dst.insert(dst.end(), source.begin(), source.end());
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

Bytes grid_payload(const Grid& image) {
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
  std::uint16_t auxiliary_to{};
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
    if (item.auxiliary_to) {
      const std::array<std::uint32_t,1> master{item.auxiliary_to};
      append(payload, container::tmap_reference("auxl",item.id,master,false));
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
  for (const auto& item : items) {
    if (item.type != "tmap") continue;
    const auto altr=container::tmap_alternative_group(
        static_cast<std::uint32_t>(items.size()+1),item.id,primary);
    append(payload, make_box("grpl",altr));
  }
  return make_box("meta", payload);
}

void validate_sample(std::span<const std::uint8_t> sample) {
  bool idr = false;
  for (std::size_t at = 0; at < sample.size();) {
    if (sample.size() - at < 4) throw std::invalid_argument("truncated HEIF sample NAL length");
    const auto size = container::be32(sample, at); at += 4;
    if (size > sample.size() - at) throw std::invalid_argument("HEIF sample NAL out of bounds");
    const auto nal = sample.subspan(at, size);
    const auto type = container::nal_type(nal);
    if ((nal[0] & 1) || (nal[1] >> 3)) throw std::invalid_argument("HEIF requires single-layer NALs");
    if (type == 19 || type == 20) idr = true;
    else if (type != 35 && type != 38 && type != 39 && type != 40)
      throw std::invalid_argument("HEIF tile must be IDR with out-of-band parameter sets");
    at += size;
  }
  if (!idr) throw std::invalid_argument("HEIF tile has no IDR picture");
}

Grid validate_image(const HeifEncodedImage& image, const HevcConfiguration& config) {
  const auto columns = (std::uint64_t(image.width) + 511) / 512;
  const auto rows = (std::uint64_t(image.height) + 511) / 512;
  if (!columns || !rows || columns > 256 || rows > 256 || columns * rows > kMaxTiles ||
      image.sequence.samples.size() != columns * rows || config.width != 512 || config.height != 512 ||
      config.chroma_format != 1 || (config.bit_depth != 8 && config.bit_depth != 10))
    throw std::invalid_argument("HEIF requires a valid grid of 512x512 4:2:0 Main/Main10 tiles");
  if ((config.record[1] & 31) != (config.bit_depth == 8 ? 1 : 2))
    throw std::invalid_argument("HEIF requires HEVC Main/Main10 profile");
  if (image.light && image.light->average > image.light->maximum)
    throw std::invalid_argument("invalid HEIF content light levels");
  if (!image.display_p3_icc.empty()) {
    const auto icc = image.display_p3_icc;
    if (icc.size() < 128 || icc.size() > kMetadataLimit || container::be32(icc, 0) != icc.size() ||
        container::be32(icc, 36) != 0x61637370 || image.color.primaries != 12 ||
        image.color.transfer != 13 || image.color.matrix != 1 || !image.color.full_range)
      throw std::invalid_argument("HEIF Display P3 ICC requires matching authoritative nclx");
  }
  return {image.width, image.height, static_cast<std::uint32_t>(columns), static_cast<std::uint32_t>(rows)};
}

std::vector<Association> describe(const HeifEncodedImage& image, const HevcConfiguration& config,
    bool grid, PropertyPool& pool) {
  std::vector<Association> out;
  out.push_back(pool.add({make_ispe(grid ? image.width : 512, grid ? image.height : 512), false}));
  out.push_back(pool.add({make_box("pixi", Bytes{0, 0, 0, 0, 3,
      static_cast<std::uint8_t>(config.bit_depth), static_cast<std::uint8_t>(config.bit_depth),
      static_cast<std::uint8_t>(config.bit_depth)}), true}));
  Bytes nclx{'n', 'c', 'l', 'x'};
  put16(nclx, image.color.primaries); put16(nclx, image.color.transfer); put16(nclx, image.color.matrix);
  nclx.push_back(image.color.full_range ? 0x80 : 0);
  out.push_back(pool.add({make_box("colr", nclx), true}));
  if (!image.display_p3_icc.empty()) {
    Bytes icc{'p', 'r', 'o', 'f'};
    icc.insert(icc.end(), image.display_p3_icc.begin(), image.display_p3_icc.end());
    out.push_back(pool.add({make_box("colr", icc), false}));
  }
  if (image.light) {
    Bytes clli; put16(clli, image.light->maximum); put16(clli, image.light->average);
    out.push_back(pool.add({make_box("clli", clli), false}));
  }
  return out;
}
} // namespace

std::vector<std::uint8_t> write_heif(const HeifEncodedImage& base, const HeifEncodedImage* gain,
    const HeifWriteOptions& options) {
  check_cancelled();
  if (bool(gain) != options.gain_metadata.has_value() || options.exif.size() > kMetadataLimit ||
      options.xmp.size() > kMetadataLimit || (gain && base.display_p3_icc.empty()) ||
      (gain && !gain->display_p3_icc.empty()))
    throw std::invalid_argument("invalid HEIF metadata or gain-map inputs");
  const std::array<const HeifEncodedImage*, 2> images{&base, gain};
  const unsigned count = gain ? 2 : 1;
  std::vector<HevcConfiguration> configs;
  std::vector<Grid> grids;
  std::size_t tiles = 0, item_count = (gain ? 1 : 0) + !options.exif.empty() + !options.xmp.empty();
  std::uint64_t media_size = options.exif.empty() ? 0 : options.exif.size() + 4;
  media_size += options.xmp.size();
  for (unsigned group = 0; group < count; ++group) {
    const auto& image = *images[group];
    configs.push_back(make_hevc_configuration(image.sequence.vps, image.sequence.sps, image.sequence.pps));
    grids.push_back(validate_image(image, configs.back()));
    tiles += image.sequence.samples.size();
    item_count += image.sequence.samples.size() + ((image.width != 512 || image.height != 512));
    for (const auto& sample : image.sequence.samples) {
      check_cancelled();
      media_size = container::bounded_heif_add(media_size,sample.size());
      validate_sample(sample);
    }
  }
  // Leave bounded space for all meta boxes, grid descriptors and tmap payload.
  if (tiles > kMaxTiles) throw std::invalid_argument("HEIF exceeds 4096 coded tiles across base and gain map");
  if (item_count > kMaxItems || media_size > kFileLimit - 16U*1024*1024)
    throw std::invalid_argument("HEIF exceeds bounded item/file limits");
  Bytes tmap;
  if (gain) tmap = serialize_tmap_payload(*options.gain_metadata);
  PropertyPool pool;
  std::vector<Item> items;
  std::array<std::uint16_t, 2> logical_ids{};
  std::vector<Association> base_description;
  for (unsigned group = 0; group < count; ++group) {
    check_cancelled();
    const auto& image = *images[group];
    const auto& config = configs[group];
    const bool grid = (image.width != 512 || image.height != 512);
    const auto logical_id = static_cast<std::uint16_t>(items.size() + 1);
    logical_ids[group] = logical_id;
    auto description = describe(image, config, grid, pool);
    if (!group) base_description = description;
    Item logical{logical_id, grid ? "grid" : "hvc1", group ? "Gain map" : "Image",
                 group != 0, grid ? grid_payload(grids[group]) : image.sequence.samples[0], description, {}, {}, 0};
    const auto hvcc = pool.add({make_box("hvcC", config.record), true});
    if (!grid) logical.properties.push_back(hvcc);
    items.push_back(std::move(logical));
    if (grid) {
      auto tile_description = describe(HeifEncodedImage{image.sequence, 512, 512, image.color,
          image.light, image.display_p3_icc}, config, false, pool);
      tile_description.push_back(hvcc);
      for (const auto& sample : image.sequence.samples) {
        check_cancelled();
        const auto id = static_cast<std::uint16_t>(items.size() + 1);
        items[logical_id - 1].derived_from.push_back(id);
        items.push_back({id, "hvc1", "Tile", true, sample, tile_description, {}, {}, 0});
      }
    }
  }
  const auto primary = logical_ids[0];
  if (gain) {
    auto& gain_item = items[logical_ids[1] - 1];
    gain_item.properties.push_back(pool.add({container::iso_gain_map_aux_property(), true}));
    gain_item.auxiliary_to = primary;
    const auto id = static_cast<std::uint16_t>(items.size() + 1);
    items.push_back({id, "tmap", "Tone map", false, std::move(tmap), base_description,
        {primary, logical_ids[1]}, {}, 0});
  }
  if (!options.exif.empty()) {
    Bytes exif{0, 0, 0, 0}; append(exif, options.exif);
    items.push_back({static_cast<std::uint16_t>(items.size()+1), "Exif", "Exif", true, std::move(exif), {}, {}, {}, 0});
  }
  if (!options.xmp.empty()) items.push_back({static_cast<std::uint16_t>(items.size()+1), "mime", "XMP",
      true, Bytes(options.xmp.begin(), options.xmp.end()), {}, {}, "application/rdf+xml", 0});
  const auto major = configs[0].bit_depth == 8 ? "heic" : "heix";
  Bytes brands(major, major + 4); put32(brands, 0);
  brands.insert(brands.end(), {'m','i','f','1'});
  bool eight = false, ten = false;
  for (const auto& config : configs) { eight |= config.bit_depth == 8; ten |= config.bit_depth == 10; }
  if (eight) brands.insert(brands.end(), {'h','e','i','c'});
  if (ten) brands.insert(brands.end(), {'h','e','i','x'});
  if (gain) brands.insert(brands.end(), {'t','m','a','p'});
  const auto ftyp = make_box("ftyp", brands);
  const auto hdlr = make_box("hdlr", Bytes{0,0,0,0,0,0,0,0,'p','i','c','t',0,0,0,0,0,0,0,0,0,0,0,0,0});
  auto meta = make_meta(items, pool, hdlr, primary, 0);
  const std::uint64_t media_start = ftyp.size() + std::uint64_t(meta.size()) + 8;
  media_size = 0;
  for (const auto& item : items) media_size=container::bounded_heif_add(media_size,item.data.size());
  if (media_start > kFileLimit || media_size > kFileLimit - media_start)
    throw std::invalid_argument("HEIF file exceeds 32-bit offsets");
  meta = make_meta(items, pool, hdlr, primary, media_start);
  Bytes out;
  out.reserve(static_cast<std::size_t>(media_start + media_size));
  append(out, ftyp); append(out, meta);
  put32(out, static_cast<std::uint32_t>(media_size + 8));
  out.insert(out.end(), {'m','d','a','t'});
  for (const auto& item : items) { check_cancelled(); append(out, item.data); }
  return out;
}
} // namespace hyperdr
