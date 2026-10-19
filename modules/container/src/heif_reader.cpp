#include "hyperdr/container/heif_reader.hpp"

#include <algorithm>
#include <array>
#include <functional>
#include <set>

#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/json.hpp"
#include "hyperdr/foundation/progress.hpp"
#include "hyperdr/foundation/raster_budget.hpp"
#include "internal/bmff.hpp"

namespace hyperdr {
HeifReadError::HeifReadError(std::string message, std::string feature)
    : std::runtime_error(std::move(message)), feature_(std::move(feature)) {}
std::string HeifReadError::detail_json() const {
  if (feature_.empty()) return {};
  json::Writer w;
  w.begin_object().member("container", "heif").member("feature", feature_).end_object();
  return w.take();
}
namespace {
using namespace container;
using Span = std::span<const std::uint8_t>;
struct Node {
  BmffBox box;
  unsigned depth{};
  std::size_t parent{};
};
constexpr auto no_parent = std::numeric_limits<std::size_t>::max();
class Parser {
 public:
  explicit Parser(Span bytes) {
    file.bytes = bytes;
    walk(bytes, 0, 0, no_parent);
  }
  HeifFile parse();

 private:
  HeifFile file;
  std::vector<Node> nodes;
  std::size_t count{};
  void walk(Span data, std::uint64_t origin, unsigned depth, std::size_t parent) {
    auto boxes = bmff_boxes(data, origin, depth, count);
    for (auto& box : boxes) {
      const auto index = nodes.size();
      nodes.push_back({box, depth, parent});
      file.boxes.push_back({box.type, box.offset, box.size, depth});
      unsigned skip = 0;
      bool descend = true;
      if (box.type == "meta" || box.type == "iref")
        skip = 4;
      else if (box.type == "iinf") {
        BmffCursor c(box.payload);
        auto [v, flags] = bmff_fullbox(c, 1);
        (void)flags;
        c.integer(v ? 4 : 2);
        skip = static_cast<unsigned>(c.position());
      } else if (box.type != "iprp" && box.type != "ipco" && box.type != "grpl" &&
                 box.type != "dinf")
        descend = false;
      if (descend) {
        require_heif(skip <= box.payload.size(), "truncated HEIF container");
        if (skip < box.payload.size())
          walk(box.payload.subspan(skip), box.offset + box.header + skip, depth + 1, index);
      }
    }
  }
  std::vector<std::size_t> children(std::size_t parent, const std::string& type = {}) const {
    std::vector<std::size_t> out;
    for (std::size_t i = 0; i < nodes.size(); ++i)
      if (nodes[i].parent == parent && (type.empty() || nodes[i].box.type == type))
        out.push_back(i);
    return out;
  }
  std::size_t one(std::size_t parent, const std::string& type, bool required = true) const {
    auto list = children(parent, type);
    require_heif(list.size() <= 1, "duplicate HEIF singleton box");
    if (list.empty()) {
      if (required) throw HeifReadError("missing HEIF " + type + " box");
      return no_parent;
    }
    return list[0];
  }
  void iinf(std::size_t index);
  void iloc(std::size_t index, std::size_t meta);
  void iprp(std::size_t index);
  void iref(std::size_t index);
  void groups(std::size_t index);
};
unsigned width_field(unsigned value) {
  require_heif(value == 0 || value == 4 || value == 8, "invalid HEIF location field width");
  return value;
}
HeifItem& existing(HeifFile& f, std::uint32_t id) {
  auto i = f.items.find(id);
  require_heif(i != f.items.end(), "HEIF box references a missing item");
  return i->second;
}
void Parser::iinf(std::size_t index) {
  BmffCursor head(nodes[index].box.payload);
  auto [v, flags] = bmff_fullbox(head, 1);
  require_heif(!flags, "invalid iinf flags");
  auto n = head.integer(v ? 4 : 2);
  require_heif(n <= heif_limits::items, "too many HEIF items");
  auto kids = children(index);
  require_heif(kids.size() == n, "iinf entry count mismatch");
  for (auto child : kids) {
    require_heif(nodes[child].box.type == "infe", "invalid iinf child");
    BmffCursor c(nodes[child].box.payload);
    auto [version, infe_flags] = bmff_fullbox(c, 3);
    require_heif(version == 2 || version == 3, "unsupported infe version");
    require_heif(!(infe_flags & ~1U), "invalid infe flags");
    HeifItem item;
    item.id = static_cast<std::uint32_t>(c.integer(version == 2 ? 2 : 4));
    require_heif(item.id, "zero HEIF item id");
    if (c.integer(2)) throw HeifReadError("protected HEIF item", "protected_item");
    item.type = c.text(4);
    item.hidden = infe_flags & 1;
    c.cstring();
    if (item.type == "mime") {
      item.content_type = c.cstring();
      if (c.remaining()) c.cstring();
    } else if (item.type == "uri ") {
      c.cstring();
    }
    c.end();
    require_heif(file.items.emplace(item.id, std::move(item)).second, "duplicate HEIF item id");
  }
}
void Parser::iloc(std::size_t index, std::size_t meta) {
  BmffCursor c(nodes[index].box.payload);
  auto [version, flags] = bmff_fullbox(c, 2);
  require_heif(!flags, "invalid iloc flags");
  auto sizes = c.integer(1), extra = c.integer(1);
  auto off = width_field(sizes >> 4), len = width_field(sizes & 15), base = width_field(extra >> 4),
       ix = width_field(version ? extra & 15 : 0);
  require_heif(version || !(extra & 15), "invalid iloc reserved bits");
  auto count = c.integer(version == 2 ? 4 : 2);
  require_heif(count <= heif_limits::items, "too many iloc entries");
  auto idat = one(meta, "idat", false);
  std::set<std::uint32_t> seen;
  std::size_t extents = 0;
  for (std::uint64_t i = 0; i < count; ++i) {
    auto id = static_cast<std::uint32_t>(c.integer(version == 2 ? 4 : 2));
    auto& item = existing(file, id);
    require_heif(seen.insert(id).second, "duplicate iloc item");
    auto method = version ? c.integer(2) : 0;
    require_heif(!(method & ~15ULL), "invalid iloc reserved bits");
    if (method == 2)
      throw HeifReadError("iloc item-offset construction unsupported", "construction_method");
    require_heif(method <= 2, "invalid iloc construction method");
    if (c.integer(2))
      throw HeifReadError("external HEIF data references unsupported", "external_reference");
    auto base_offset = c.integer(base), n = c.integer(2);
    require_heif(n <= heif_limits::extents - extents, "too many HEIF extents");
    extents += static_cast<std::size_t>(n);
    std::uint64_t start = 0, available = file.bytes.size();
    if (method == 1) {
      require_heif(idat != no_parent, "iloc references missing idat");
      start = nodes[idat].box.offset + nodes[idat].box.header;
      available = nodes[idat].box.payload.size();
    }
    for (std::uint64_t j = 0; j < n; ++j) {
      c.integer(ix);
      auto offset = heif_add(base_offset, c.integer(off)), length = c.integer(len);
      require_heif(offset <= available && length <= available - offset,
                   "HEIF extent exceeds its data source");
      item.extents.push_back({heif_add(start, offset), length});
    }
  }
  c.end();
}
void Parser::iprp(std::size_t index) {
  auto ipco = one(index, "ipco");
  for (auto i : children(ipco)) {
    require_heif(file.properties.size() < heif_limits::properties, "too many HEIF properties");
    file.properties.push_back({nodes[i].box.type, nodes[i].box.payload});
  }
  std::set<std::uint32_t> seen;
  for (auto index : children(index, "ipma")) {
    BmffCursor c(nodes[index].box.payload);
    auto [v, flags] = bmff_fullbox(c, 1);
    require_heif(!(flags & ~1U), "invalid ipma flags");
    auto n = c.integer(4);
    require_heif(n <= heif_limits::items, "too many ipma entries");
    for (std::uint64_t i = 0; i < n; ++i) {
      auto id = static_cast<std::uint32_t>(c.integer(v ? 4 : 2));
      auto& item = existing(file, id);
      require_heif(seen.insert(id).second, "duplicate ipma item");
      auto count = c.integer(1);
      require_heif(count <= heif_limits::associations, "too many HEIF property associations");
      for (std::uint64_t j = 0; j < count; ++j) {
        auto raw = c.integer(flags & 1 ? 2 : 1);
        std::uint64_t mask = flags & 1 ? 0x7FFFU : 0x7FU;
        auto p = raw & mask;
        require_heif(p <= file.properties.size(), "ipma property index out of bounds");
        if (!p) {
          require_heif(!(raw & ~mask), "essential null property");
          continue;
        }
        item.properties.push_back({static_cast<std::uint16_t>(p), (raw & ~mask) != 0});
      }
    }
    c.end();
  }
}
void Parser::iref(std::size_t index) {
  BmffCursor head(nodes[index].box.payload);
  auto [v, flags] = bmff_fullbox(head, 1);
  require_heif(!flags, "invalid iref flags");
  std::set<std::pair<std::uint32_t, std::string>> seen;
  std::size_t total = 0;
  for (auto i : children(index)) {
    const auto& box = nodes[i].box;
    BmffCursor c(box.payload);
    HeifReference ref;
    ref.type = box.type;
    ref.from = static_cast<std::uint32_t>(c.integer(v ? 4 : 2));
    existing(file, ref.from);
    auto n = c.integer(2);
    require_heif(n <= heif_limits::grid_tiles - total, "too many HEIF references");
    total += static_cast<std::size_t>(n);
    require_heif(seen.emplace(ref.from, ref.type).second, "duplicate HEIF item reference");
    for (std::uint64_t j = 0; j < n; ++j) {
      auto id = static_cast<std::uint32_t>(c.integer(v ? 4 : 2));
      existing(file, id);
      ref.to.push_back(id);
    }
    c.end();
    file.references.push_back(std::move(ref));
  }
}
void Parser::groups(std::size_t index) {
  std::set<std::uint32_t> seen;
  for (auto i : children(index)) {
    const auto& b = nodes[i].box;
    BmffCursor c(b.payload);
    auto [v, flags] = bmff_fullbox(c);
    (void)v;
    require_heif(!flags, "invalid HEIF group flags");
    HeifGroup g;
    g.type = b.type;
    g.id = static_cast<std::uint32_t>(c.integer(4));
    require_heif(g.id && !file.items.contains(g.id) && seen.insert(g.id).second,
                 "entity group id collides with an item or group");
    auto n = c.integer(4);
    require_heif(n <= heif_limits::items, "too many HEIF group members");
    for (std::uint64_t j = 0; j < n; ++j) {
      auto id = static_cast<std::uint32_t>(c.integer(4));
      existing(file, id);
      g.members.push_back(id);
    }
    c.end();
    file.groups.push_back(std::move(g));
  }
}
HeifFile Parser::parse() {
  auto ftyp = one(no_parent, "ftyp");
  BmffCursor f(nodes[ftyp].box.payload);
  require_heif(f.remaining() >= 8 && !(f.remaining() % 4), "truncated ftyp box");
  file.brands.push_back(f.text(4));
  f.take(4);
  while (f.remaining()) file.brands.push_back(f.text(4));
  for (const auto& brand : file.brands)
    if (brand == "msf1" || brand == "hevc" || brand == "hevx" || brand == "hevs")
      throw HeifReadError("HEIF image sequences unsupported", "image_sequence");
  auto meta = one(no_parent, "meta");
  BmffCursor m(nodes[meta].box.payload);
  auto [version, flags] = bmff_fullbox(m);
  (void)version;
  require_heif(!flags, "invalid meta flags");
  auto hdlr = one(meta, "hdlr");
  BmffCursor h(nodes[hdlr].box.payload);
  auto [hv, hf] = bmff_fullbox(h);
  (void)hv;
  require_heif(!hf, "invalid hdlr flags");
  h.take(4);
  if (h.text(4) != "pict") throw HeifReadError("HEIF handler is not pict", "handler");
  require_heif(h.remaining() >= 12, "truncated hdlr");
  iinf(one(meta, "iinf"));
  auto pitm = one(meta, "pitm");
  BmffCursor p(nodes[pitm].box.payload);
  auto [pv, pf] = bmff_fullbox(p, 1);
  require_heif(!pf, "invalid pitm flags");
  file.primary_item_id = static_cast<std::uint32_t>(p.integer(pv ? 4 : 2));
  p.end();
  existing(file, file.primary_item_id);
  iloc(one(meta, "iloc"), meta);
  iprp(one(meta, "iprp"));
  auto refs = one(meta, "iref", false);
  if (refs != no_parent) iref(refs);
  auto grpl = one(meta, "grpl", false);
  if (grpl != no_parent) groups(grpl);
  file.has_data_information = one(meta, "dinf", false) != no_parent;
  // Detect dimg cycles in O(items + edges), without recursive graph traversal.
  // auxl and prem may legitimately point in opposite directions.
  std::map<std::uint32_t, std::vector<std::uint32_t>> derived;
  std::map<std::uint32_t, std::size_t> indegree;
  for (const auto& [id, item] : file.items) {
    (void)item;
    indegree[id] = 0;
  }
  for (const auto& ref : file.references)
    if (ref.type == "dimg") {
      derived[ref.from] = ref.to;
      for (auto id : ref.to) ++indegree[id];
    }
  std::vector<std::uint32_t> ready;
  for (auto [id, n] : indegree)
    if (!n) ready.push_back(id);
  for (std::size_t i = 0; i < ready.size(); ++i)
    for (auto id : derived[ready[i]])
      if (!--indegree[id]) ready.push_back(id);
  require_heif(ready.size() == file.items.size(), "HEIF derived reference cycle");
  // Validate bounded metadata and property syntax even on hidden items. Unknown
  // essential properties are judged only when the corresponding image is used.
  for (const auto& prop : file.properties) {
    BmffCursor c(prop.payload);
    if (prop.type == "colr") {
      auto type = c.text(4);
      if (type == "prof" || type == "rICC")
        require_heif(c.remaining() <= heif_limits::icc_bytes, "HEIF ICC exceeds limit");
      else if (type == "nclx") {
        c.take(6);
        require_heif(!(c.integer(1) & 127), "invalid nclx reserved bits");
        c.end();
      }
    } else if (prop.type == "ispe") {
      bmff_fullbox(c);
      auto w = c.integer(4), h = c.integer(4);
      require_heif(w && h && w < 0x80000000ULL && h < 0x80000000ULL, "invalid ispe dimensions");
      c.end();
    } else if (prop.type == "irot" || prop.type == "imir") {
      auto value = c.integer(1);
      require_heif(value <= (prop.type == "irot" ? 3U : 1U),
                   "invalid HEIF transform reserved bits");
      c.end();
    } else if (prop.type == "clap") {
      for (int i = 0; i < 4; ++i) {
        c.integer(4);
        require_heif(c.integer(4), "zero HEIF clap denominator");
      }
      c.end();
    } else if (prop.type == "hvcC") {
      (void)parse_hevc_configuration(prop.payload);
    } else if (prop.type == "auxC") {
      bmff_fullbox(c);
      c.cstring();
    } else if (prop.type == "clli") {
      c.take(4);
      c.end();
    } else if (prop.type == "mdcv") {
      c.take(24);
      c.end();
    } else if (prop.type == "pixi") {
      bmff_fullbox(c);
      auto n = c.integer(1);
      require_heif(n >= 1 && n <= 4, "invalid pixi channel count");
      for (std::uint64_t i = 0; i < n; ++i) require_heif(c.integer(1) > 0, "invalid pixi depth");
      c.end();
    }
  }
  for (const auto& [id, item] : file.items) {
    if (item.type == "hvc1" || item.type == "hev1") {
      std::uint64_t total = 0;
      for (auto extent : item.extents) total = heif_add(total, extent.length);
      require_heif(total <= heif_limits::sample_bytes, "HEVC item exceeds sample limit");
    }
    if (item.type == "Exif") {
      auto bytes = file.item_bytes(id, heif_limits::metadata_bytes);
      BmffCursor c(bytes);
      auto offset = c.integer(4);
      require_heif(offset <= c.remaining() && c.remaining() - offset >= 8,
                   "HEIF Exif TIFF offset exceeds payload");
    }
    if (item.type == "mime" && item.content_type == "application/rdf+xml")
      (void)file.item_bytes(id, heif_limits::metadata_bytes);
    if (item.type == "tmap") {
      auto bytes = file.item_bytes(id, 4096);
      try {
        (void)parse_tmap_payload(bytes);
      } catch (const std::exception& e) {
        throw HeifReadError(e.what());
      }
    }
  }
  return std::move(file);
}
const std::set<std::string> known_properties{"ispe", "pixi", "colr", "clli", "mdcv",
                                             "irot", "imir", "clap", "auxC", "hvcC"};
void admit_raster(std::uint32_t width, std::uint32_t height) {
  require_heif(raster_input_budget_ok(width, height), "HEIF image exceeds raster budget");
}
struct Description {
  std::uint32_t width{}, height{};
  std::optional<HvcConfig> config;
  std::vector<const HeifProperty*> transforms;
};
Description describe(const HeifFile& file, const HeifItem& item, HeifImagePlan& out) {
  Description d;
  std::set<std::string> seen;
  for (auto a : item.properties) {
    const auto& p = file.properties.at(a.index - 1);
    if (!known_properties.contains(p.type)) {
      if (a.essential)
        throw HeifReadError("unknown essential HEIF property: " + p.type, "essential_property");
      continue;
    }
    BmffCursor c(p.payload);
    if (p.type != "colr" && p.type != "irot" && p.type != "imir" && p.type != "clap")
      require_heif(seen.insert(p.type).second, "duplicate HEIF image property");
    if (p.type == "ispe") {
      bmff_fullbox(c);
      d.width = c.integer(4);
      d.height = c.integer(4);
    } else if (p.type == "hvcC")
      d.config = parse_hevc_configuration(p.payload);
    else if (p.type == "irot" || p.type == "imir" || p.type == "clap")
      d.transforms.push_back(&p);
    else if (p.type == "colr") {
      auto kind = c.text(4);
      if (kind == "nclx") {
        require_heif(!out.color, "duplicate HEIF nclx");
        HeifNclx color;
        color.primaries = c.integer(2);
        color.transfer = c.integer(2);
        color.matrix = c.integer(2);
        color.full_range = c.integer(1) & 128;
        out.color = color;
      } else if (kind == "prof" || kind == "rICC") {
        require_heif(out.icc.empty(), "duplicate HEIF ICC");
        out.icc = c.take(c.remaining());
      }
    } else if (p.type == "clli")
      out.light = HeifContentLight{static_cast<std::uint16_t>(c.integer(2)),
                                   static_cast<std::uint16_t>(c.integer(2))};
    else if (p.type == "mdcv")
      out.mastering_display = p.payload;
    else if (p.type == "pixi") {
      bmff_fullbox(c);
      auto n = c.integer(1);
      for (std::uint64_t i = 0; i < n; ++i)
        out.channel_bits.push_back(static_cast<unsigned>(c.integer(1)));
    }
  }
  require_heif(d.width && d.height, "HEIF image lacks ispe");
  return d;
}
void transforms(const Description& d, HeifImagePlan& out) {
  auto w = out.width, h = out.height;
  for (const auto& existing : out.transforms) {
    if (existing.type == "irot" && (existing.value & 1))
      std::swap(w, h);
    else if (existing.type == "clap") {
      w = existing.width;
      h = existing.height;
    }
  }
  for (const auto* p : d.transforms) {
    BmffCursor c(p->payload);
    HeifTransform t;
    t.type = p->type;
    if (t.type == "irot") {
      t.value = static_cast<unsigned>(c.integer(1));
      if (t.value & 1) std::swap(w, h);
    } else if (t.type == "imir")
      t.value = static_cast<unsigned>(c.integer(1));
    else {
      std::array<std::uint32_t, 8> v{};
      for (auto& n : v) n = static_cast<std::uint32_t>(c.integer(4));
      require_heif(v[1] && v[3] && v[5] && v[7], "zero HEIF clap denominator");
      require_heif(v[0] % v[1] == 0 && v[2] % v[3] == 0, "fractional HEIF clap dimensions");
      auto cw = v[0] / v[1], ch = v[2] / v[3];
      require_heif(cw && ch && cw <= w && ch <= h, "HEIF clap exceeds image");
      auto start = [](std::uint32_t size, std::uint32_t crop, std::uint32_t num,
                      std::uint32_t den) {
        auto n = __int128(size - crop) * den + __int128(static_cast<std::int32_t>(num)) * 2;
        auto divisor = __int128(den) * 2;
        require_heif(n >= 0 && n % divisor == 0 && n / divisor <= size - crop,
                     "HEIF clap is outside image or fractional");
        return static_cast<std::uint32_t>(n / divisor);
      };
      t.left = start(w, cw, v[4], v[5]);
      t.top = start(h, ch, v[6], v[7]);
      t.width = cw;
      t.height = ch;
      w = cw;
      h = ch;
    }
    out.transforms.push_back(t);
  }
}
HeifImagePlan resolve(const HeifFile& f, std::uint32_t id, unsigned depth,
                      std::set<std::uint32_t>& visited) {
  require_heif(depth <= 2 && visited.insert(id).second,
               "HEIF derived image chain is too deep or cyclic");
  const auto& item = f.item(id);
  HeifImagePlan out;
  out.item_id = id;
  auto d = describe(f, item, out);
  out.width = d.width;
  out.height = d.height;
  admit_raster(out.width, out.height);
  if (item.type == "hvc1" || item.type == "hev1") {
    require_heif(d.config.has_value(), "HEVC item lacks hvcC");
    out.config = *d.config;
    out.tile_width = out.config.width;
    out.tile_height = out.config.height;
    require_heif(out.width == out.tile_width && out.height == out.tile_height,
                 "HEIF ispe differs from HEVC SPS");
    auto bytes = f.item_bytes(id);
    validate_hevc_sample(bytes, out.config);
    out.tiles.push_back({id, item.extents});
  } else if (item.type == "grid") {
    require_heif(depth <= 1, "nested HEIF grid unsupported");
    auto bytes = f.item_bytes(id, 12);
    BmffCursor c(bytes);
    require_heif(c.integer(1) == 0, "unsupported HEIF grid version");
    auto flags = c.integer(1);
    require_heif(!(flags & ~1ULL), "invalid HEIF grid flags");
    out.rows = static_cast<std::uint32_t>(c.integer(1)) + 1;
    out.columns = static_cast<std::uint32_t>(c.integer(1)) + 1;
    auto w = c.integer(flags & 1 ? 4 : 2), h = c.integer(flags & 1 ? 4 : 2);
    c.end();
    require_heif(w == out.width && h == out.height, "HEIF grid dimensions differ from ispe");
    auto refs = f.targets(id, "dimg");
    require_heif(checked_grid_tile_count(out.rows, out.columns) <= heif_limits::grid_tiles &&
                     refs.size() == std::uint64_t(out.rows) * out.columns,
                 "HEIF grid tile count mismatch");
    std::set<std::uint32_t> checked_tiles;
    for (auto tile_id : refs) {
      const auto& tile = f.item(tile_id);
      require_heif(tile.type == "hvc1" || tile.type == "hev1", "HEIF grid tile is not coded");
      const HeifProperty* config = nullptr;
      std::uint32_t width = 0, height = 0;
      std::set<std::string> seen;
      for (auto association : tile.properties) {
        const auto& property = f.properties.at(association.index - 1);
        if (!known_properties.contains(property.type)) {
          if (association.essential)
            throw HeifReadError("unknown essential HEIF tile property", "essential_property");
          continue;
        }
        require_heif(property.type != "irot" && property.type != "imir" && property.type != "clap",
                     "HEIF grid tile carries transforms");
        if (property.type == "ispe" || property.type == "hvcC") {
          require_heif(seen.insert(property.type).second, "duplicate HEIF tile property");
          if (property.type == "hvcC")
            config = &property;
          else {
            BmffCursor c(property.payload);
            bmff_fullbox(c);
            width = c.integer(4);
            height = c.integer(4);
          }
        }
      }
      require_heif(config && width && height, "HEIF grid tile lacks ispe or hvcC");
      if (out.tiles.empty()) {
        // A derived image may omit its colour properties and inherit those of
        // its first coded input (for example Sony HLG grids). Explicit grid
        // properties take precedence over the coded input.
        HeifImagePlan input;
        (void)describe(f, tile, input);
        if (!out.color) out.color = input.color;
        if (out.icc.empty()) out.icc = input.icc;
        if (!out.light) out.light = input.light;
        if (out.mastering_display.empty()) out.mastering_display = input.mastering_display;
        if (out.channel_bits.empty()) out.channel_bits = std::move(input.channel_bits);
        out.config = parse_hevc_configuration(config->payload);
        out.tile_width = out.config.width;
        out.tile_height = out.config.height;
      }
      require_heif(
          width == out.tile_width && height == out.tile_height &&
              config->payload.size() == out.config.record.size() &&
              std::equal(config->payload.begin(), config->payload.end(), out.config.record.begin()),
          "HEIF grid tiles differ in dimensions or hvcC");
      // An item may be reused by several cells. Validate its bytes once; the
      // resulting plan retains spans, so adversarial reference repetition does
      // not amplify extent or parameter-set allocations.
      if (checked_tiles.insert(tile_id).second) {
        auto sample = f.item_bytes(tile_id);
        validate_hevc_sample(sample, out.config);
      }
      out.tiles.push_back({tile_id, tile.extents});
    }
    require_heif(std::uint64_t(out.columns) * out.tile_width >= out.width &&
                     std::uint64_t(out.rows) * out.tile_height >= out.height &&
                     std::uint64_t(out.columns - 1) * out.tile_width < out.width &&
                     std::uint64_t(out.rows - 1) * out.tile_height < out.height,
                 "HEIF grid does not cover output dimensions");
  } else if (item.type == "iden") {
    auto refs = f.targets(id, "dimg");
    require_heif(refs.size() == 1, "HEIF identity image must reference one image");
    require_heif(f.item(refs[0]).type != "iden", "HEIF identity chain is too deep");
    auto child = resolve(f, refs[0], depth + 1, visited);
    require_heif(child.width == out.width && child.height == out.height,
                 "HEIF identity dimensions differ from source");
    if (!out.color) out.color = child.color;
    if (out.icc.empty()) out.icc = child.icc;
    if (!out.light) out.light = child.light;
    if (out.channel_bits.empty()) out.channel_bits = std::move(child.channel_bits);
    out.config = std::move(child.config);
    out.tile_width = child.tile_width;
    out.tile_height = child.tile_height;
    out.rows = child.rows;
    out.columns = child.columns;
    out.tiles = std::move(child.tiles);
    out.transforms = std::move(child.transforms);
  } else
    throw HeifReadError("HEIF item codec is unsupported: " + item.type, "codec");
  transforms(d, out);
  visited.erase(id);
  return out;
}
}  // namespace
HeifFile read_heif(std::span<const std::uint8_t> bytes) {
  try {
    return Parser(bytes).parse();
  } catch (const HeifReadError&) {
    throw;
  } catch (const std::exception& e) {
    throw HeifReadError(e.what());
  }
}
const HeifItem& HeifFile::item(std::uint32_t id) const {
  auto i = items.find(id);
  if (i == items.end()) throw HeifReadError("missing HEIF item");
  return i->second;
}
std::vector<std::uint8_t> HeifFile::item_bytes(std::uint32_t id, std::size_t limit) const {
  const auto& entry = item(id);
  std::size_t total = 0;
  for (auto e : entry.extents) {
    container::require_heif(e.offset <= bytes.size() && e.length <= bytes.size() - e.offset &&
                                e.length <= limit - total,
                            "HEIF item exceeds payload limit");
    total += static_cast<std::size_t>(e.length);
  }
  std::vector<std::uint8_t> out;
  out.reserve(total);
  for (auto e : entry.extents) {
    auto s = bytes.subspan(static_cast<std::size_t>(e.offset), static_cast<std::size_t>(e.length));
    out.insert(out.end(), s.begin(), s.end());
  }
  return out;
}
std::vector<std::uint32_t> HeifFile::targets(std::uint32_t id, const std::string& type) const {
  for (const auto& r : references)
    if (r.from == id && r.type == type) return r.to;
  return {};
}
HeifImagePlan HeifFile::resolve_image(std::uint32_t id) const {
  std::set<std::uint32_t> path;
  return resolve(*this, id ? id : primary_item_id, 0, path);
}
std::optional<TmapReferences> HeifFile::tmap_references() const {
  std::optional<TmapReferences> out;
  for (const auto& [id, item] : items)
    if (item.type == "tmap") {
      // A metadata item is consumed too: its essential properties have the same
      // contract as those on the base and gain images, without requiring ispe.
      for (const auto association : item.properties) {
        const auto& property = properties.at(association.index - 1);
        if (association.essential && !known_properties.contains(property.type))
          throw HeifReadError("unknown essential HEIF tmap property: " + property.type,
                              "essential_property");
      }
      auto refs = targets(id, "dimg");
      container::require_heif(refs.size() == 2, "tmap dimg must contain exactly [base, gain]");
      auto base = refs[0], gain = refs[1];
      container::require_heif(base && gain && base != gain && base != id && gain != id,
                              "invalid tmap dimg item ids");
      container::require_heif(!out, "multiple tmap items unsupported");
      out = TmapReferences{id, base, gain};
    }
  return out;
}
std::string HeifFile::auxiliary_type(std::uint32_t id) const {
  for (auto a : item(id).properties) {
    const auto& p = properties.at(a.index - 1);
    if (p.type == "auxC") {
      container::BmffCursor c(p.payload);
      container::bmff_fullbox(c);
      return c.cstring();
    }
  }
  return {};
}
std::optional<HeifGainMapPlan> HeifFile::resolve_gain_map() const {
  if (auto refs = tmap_references()) {
    container::require_heif(refs->base_id == primary_item_id, "tmap base is not the primary image");
    bool group = false;
    for (const auto& g : groups)
      if (g.type == "altr" &&
          g.members == std::vector<std::uint32_t>{refs->tmap_id, primary_item_id}) {
        container::require_heif(!group, "duplicate tmap altr group");
        group = true;
      }
    container::require_heif(group, "missing tmap altr group");
    auto data = item_bytes(refs->tmap_id, 4096);
    HeifGainMapPlan out{resolve_image(refs->base_id), resolve_image(refs->gain_id),
                        parse_tmap_payload(data), refs->tmap_id};
    container::require_heif(out.gain.width <= out.base.width && out.gain.height <= out.base.height,
                            "HEIF gain map exceeds base dimensions");
    if (out.metadata->channels.size() == 3)
      container::require_heif(out.gain.config.chroma_format != 0,
                              "HEIF gain map channel count mismatch");
    return out;
  }
  for (const auto& [id, item] : items) {
    (void)item;
    auto targets_ = targets(id, "auxl");
    if (std::find(targets_.begin(), targets_.end(), primary_item_id) != targets_.end() &&
        auxiliary_type(id) == "urn:com:apple:photo:2020:aux:hdrgainmap") {
      HeifGainMapPlan plan{resolve_image(), resolve_image(id), std::nullopt, 0};
      container::require_heif(
          plan.gain.width <= plan.base.width && plan.gain.height <= plan.base.height,
          "HEIF gain map exceeds base dimensions");
      return plan;
    }
  }
  return {};
}
std::optional<HeifAlphaPlan> HeifFile::resolve_alpha(std::uint32_t base) const {
  if (!base) base = primary_item_id;
  std::optional<HeifAlphaPlan> out;
  for (const auto& [id, item] : items) {
    (void)item;
    auto refs = targets(id, "auxl");
    if (std::find(refs.begin(), refs.end(), base) == refs.end()) continue;
    auto urn = auxiliary_type(id);
    if (urn != "urn:mpeg:hevc:2015:auxid:1" && urn != "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha")
      continue;
    container::require_heif(!out, "multiple HEIF alpha images");
    auto prem = targets(base, "prem");
    auto image = resolve_image(id);
    auto primary = resolve_image(base);
    container::require_heif(image.width == primary.width && image.height == primary.height,
                            "HEIF alpha dimensions differ from base");
    out = HeifAlphaPlan{std::move(image), std::find(prem.begin(), prem.end(), id) != prem.end()};
  }
  return out;
}
std::vector<std::uint8_t> HeifFile::exif(std::uint32_t image) const {
  if (!image) image = primary_item_id;
  for (const auto& [id, item] : items)
    if (item.type == "Exif") {
      auto refs = targets(id, "cdsc");
      if (!refs.empty() && std::find(refs.begin(), refs.end(), image) == refs.end()) continue;
      auto data = item_bytes(id, heif_limits::metadata_bytes);
      container::BmffCursor c(data);
      auto offset = c.integer(4);
      container::require_heif(offset <= c.remaining(), "HEIF Exif TIFF offset exceeds payload");
      c.take(static_cast<std::size_t>(offset));
      auto tiff = c.take(c.remaining());
      return {tiff.begin(), tiff.end()};
    }
  return {};
}
std::string HeifFile::xmp(std::uint32_t image) const {
  if (!image) image = primary_item_id;
  for (const auto& [id, item] : items)
    if (item.type == "mime" && item.content_type == "application/rdf+xml") {
      auto refs = targets(id, "cdsc");
      if (!refs.empty() && std::find(refs.begin(), refs.end(), image) == refs.end()) continue;
      auto data = item_bytes(id, heif_limits::metadata_bytes);
      return {data.begin(), data.end()};
    }
  return {};
}
std::string HeifFile::normalized_json() const {
  json::Writer w;
  w.begin_object().member("primary", primary_item_id).begin_array("brands");
  for (const auto& brand : brands) w.element(brand);
  w.end_array().begin_array("items");
  for (const auto& [id, item] : items) {
    w.begin_object()
        .member("id", id)
        .member("type", item.type)
        .member("hidden", item.hidden)
        .member("content_type", item.content_type)
        .begin_array("extents");
    for (auto e : item.extents)
      w.begin_object().member("offset", e.offset).member("length", e.length).end_object();
    w.end_array().begin_array("properties");
    for (auto a : item.properties)
      w.begin_object().member("index", a.index).member("essential", a.essential).end_object();
    w.end_array().end_object();
  }
  w.end_array().begin_array("properties");
  for (const auto& p : properties) {
    std::string hex;
    constexpr char digits[] = "0123456789abcdef";
    for (auto b : p.payload) {
      hex.push_back(digits[b >> 4]);
      hex.push_back(digits[b & 15]);
    }
    w.begin_object().member("type", p.type).member("payload", hex).end_object();
  }
  w.end_array().begin_array("images");
  for (const auto& [id, entry] : items) {
    if (entry.type != "hvc1" && entry.type != "hev1" && entry.type != "grid" &&
        entry.type != "iden")
      continue;
    const auto image = resolve_image(id);
    w.begin_object()
        .member("id", id)
        .member("width", image.width)
        .member("height", image.height)
        .member("tile_width", image.tile_width)
        .member("tile_height", image.tile_height)
        .member("columns", image.columns)
        .member("rows", image.rows)
        .member("bit_depth", image.config.bit_depth)
        .member("chroma_format", image.config.chroma_format)
        .begin_array("tiles");
    for (const auto& tile : image.tiles) w.element(tile.id);
    w.end_array().begin_array("transforms");
    for (const auto& t : image.transforms)
      w.begin_object()
          .member("type", t.type)
          .member("value", t.value)
          .member("left", t.left)
          .member("top", t.top)
          .member("width", t.width)
          .member("height", t.height)
          .end_object();
    w.end_array();
    const auto color = [&](const char* key, const std::optional<HeifNclx>& value) {
      if (value)
        w.begin_object(key)
            .member("primaries", value->primaries)
            .member("transfer", value->transfer)
            .member("matrix", value->matrix)
            .member("full_range", value->full_range)
            .end_object();
      else
        w.null_member(key);
    };
    color("nclx", image.color);
    color("vui", image.config.vui_color);
    if (image.config.chroma_location_top)
      w.member("chroma_location_top", *image.config.chroma_location_top);
    else
      w.null_member("chroma_location_top");
    if (image.config.chroma_location_bottom)
      w.member("chroma_location_bottom", *image.config.chroma_location_bottom);
    else
      w.null_member("chroma_location_bottom");
    w.member("icc_bytes", image.icc.size());
    if (image.light)
      w.begin_object("clli")
          .member("maximum", image.light->maximum)
          .member("average", image.light->average)
          .end_object();
    else
      w.null_member("clli");
    w.end_object();
  }
  w.end_array().begin_array("references");
  for (const auto& r : references) {
    w.begin_object().member("type", r.type).member("from", r.from).begin_array("to");
    for (auto id : r.to) w.element(id);
    w.end_array().end_object();
  }
  w.end_array().begin_array("groups");
  for (const auto& g : groups) {
    w.begin_object().member("type", g.type).member("id", g.id).begin_array("members");
    for (auto id : g.members) w.element(id);
    w.end_array().end_object();
  }
  w.end_array().end_object();
  return w.take();
}
}  // namespace hyperdr
