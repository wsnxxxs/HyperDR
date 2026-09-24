#include "hyperdr/codec/dcp_profile.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include <algorithm>
#include <bit>
#include <cmath>
#include <cctype>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
#if HYPERDR_WITH_CODECS
#include <zlib.h>
#endif

namespace hyperdr {
namespace {
[[noreturn]] void invalid(const std::string& reason) {
  throw std::invalid_argument("XMP look: " + reason);
}
#if HYPERDR_WITH_CODECS
// Deliberately restricted to static profile XMP; no external entities or DTD.
struct Node {
  std::string name, text;
  std::map<std::string, std::string> attributes;
  std::vector<Node> children;
  const Node* child(const std::string& key) const {
    for (const auto& item : children) if (item.name == key) return &item;
    return nullptr;
  }
};
std::string trim(std::string value) {
  const auto begin = value.find_first_not_of(" \t\r\n");
  return begin == std::string::npos ? std::string{} :
      value.substr(begin, value.find_last_not_of(" \t\r\n") - begin + 1);
}
std::string unescape(std::string_view value) {
  std::string out;
  for (std::size_t i = 0; i < value.size(); ++i) {
    if (value[i] != '&') { out += value[i]; continue; }
    const auto end = value.find(';', i);
    if (end == std::string_view::npos) invalid("unterminated XML entity");
    const auto token = value.substr(i, end-i+1);
    if (token == "&amp;") out += '&';
    else if (token == "&lt;") out += '<';
    else if (token == "&gt;") out += '>';
    else if (token == "&quot;") out += '"';
    else if (token == "&apos;") out += '\'';
    else invalid("unsupported XML entity");
    i = end;
  }
  return out;
}
Node parse_xml(const std::string& xml) {
  Node root;
  std::vector<Node*> stack{&root};
  std::size_t pos = 0;
  while (pos < xml.size()) {
    const auto start = xml.find('<', pos);
    if (start == std::string::npos) break;
    stack.back()->text += unescape(std::string_view(xml).substr(pos, start-pos));
    if (xml.compare(start, 4, "<!--") == 0) {
      const auto end = xml.find("-->", start+4);
      if (end == std::string::npos) invalid("unclosed XML comment");
      pos = end+3; continue;
    }
    char quote = 0;
    auto end = start+1;
    for (; end < xml.size(); ++end) {
      const char c = xml[end];
      if (quote) { if (c == quote) quote = 0; }
      else if (c == '\'' || c == '"') quote = c;
      else if (c == '>') break;
    }
    if (end == xml.size()) invalid("unclosed XML tag");
    auto tag = trim(xml.substr(start+1, end-start-1));
    pos = end+1;
    if (tag.empty()) invalid("empty XML tag");
    if (tag[0] == '?') continue;
    if (tag[0] == '!') invalid("XML declarations are not supported");
    if (tag[0] == '/') {
      if (stack.size() == 1 || stack.back()->name != trim(tag.substr(1))) invalid("mismatched XML tag");
      stack.pop_back(); continue;
    }
    const auto split = tag.find_first_of(" \t\r\n/");
    Node node;
    node.name = tag.substr(0, split);
    auto p = split == std::string::npos ? tag.size() : split;
    while (p < tag.size()) {
      if (std::isspace(static_cast<unsigned char>(tag[p])) || tag[p] == '/') { ++p; continue; }
      const auto eq = tag.find('=', p);
      if (eq == std::string::npos) invalid("invalid XML attribute");
      const auto key = trim(tag.substr(p, eq-p));
      p = tag.find_first_not_of(" \t\r\n", eq+1);
      if (p == std::string::npos || (tag[p] != '"' && tag[p] != '\'')) invalid("unquoted XML attribute");
      const char q = tag[p++];
      const auto stop = tag.find(q, p);
      if (stop == std::string::npos) invalid("unclosed XML attribute");
      if (!node.attributes.emplace(key, unescape(std::string_view(tag).substr(p, stop-p))).second)
        invalid("duplicate XML attribute");
      p = stop+1;
    }
    stack.back()->children.push_back(std::move(node));
    if (tag.back() != '/') {
      if (stack.size() > 24) invalid("XML nesting is too deep");
      stack.push_back(&stack.back()->children.back());
    }
  }
  if (stack.size() != 1) invalid("unclosed XML element");
  return root;
}
const Node* find_description(const Node& node) {
  if (node.name == "rdf:Description") return &node;
  for (const auto& child : node.children)
    if (const auto* found = find_description(child)) return found;
  return nullptr;
}
std::string property(const Node& node, const std::string& name) {
  const auto key = "crs:" + name;
  if (const auto it = node.attributes.find(key); it != node.attributes.end()) return it->second;
  if (const auto* child = node.child(key)) return trim(child->text);
  return {};
}
double number(const std::string& text) {
  std::size_t used{};
  const double value = std::stod(text, &used);
  if (!std::isfinite(value) || !trim(text.substr(used)).empty()) invalid("invalid curve number");
  return value;
}
std::vector<std::array<double, 2>> curve(const Node& desc, const std::string& name) {
  std::vector<std::array<double, 2>> out;
  const auto* parent = desc.child("crs:"+name);
  if (!parent) return out;
  const auto* seq = parent->child("rdf:Seq");
  if (!seq) invalid("curve requires rdf:Seq");
  for (const auto& item : seq->children) {
    if (item.name != "rdf:li") invalid("invalid curve item");
    const auto comma = item.text.find(',');
    if (comma == std::string::npos) invalid("invalid curve point");
    const double x = number(item.text.substr(0, comma))/255.0;
    const double y = number(item.text.substr(comma+1))/255.0;
    if (x < 0 || x > 1 || y < 0 || y > 1 || (!out.empty() && x <= out.back()[0]))
      invalid("curve points must be ordered in 0..255");
    out.push_back({x,y});
  }
  if (out.size() < 2 || out.front()[0] != 0 || out.back()[0] != 1) invalid("curve must span 0..255");
  return out;
}
// Adobe DNG SDK 1.7.1 dng_big_table.cpp describes the wire format:
// little-endian base85 groups, uint32 decompressed size, zlib, LookTable stream.
// No Adobe profile data is built into the program.
DcpHueSatMap look_table(std::string_view encoded) {
  constexpr std::string_view alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#";
  std::vector<std::uint8_t> packed;
  std::uint32_t value = 0, multiplier = 1;
  unsigned phase = 0;
  for (const char c : encoded) {
    if (std::isspace(static_cast<unsigned char>(c))) continue;
    const auto digit = alphabet.find(c);
    if (digit == std::string_view::npos) invalid("invalid look-table base85");
    value += static_cast<std::uint32_t>(digit)*multiplier;
    if (++phase == 5) {
      for (unsigned i = 0; i < 4; ++i) packed.push_back(static_cast<std::uint8_t>(value >> (i*8)));
      value = 0; multiplier = 1; phase = 0;
    } else multiplier *= 85;
  }
  if (phase == 1) invalid("incomplete look-table base85");
  for (unsigned i = 0; i+1 < phase; ++i) packed.push_back(static_cast<std::uint8_t>(value >> (i*8)));
  const auto u32 = [](const std::uint8_t* p) {
    return std::uint32_t(p[0]) | std::uint32_t(p[1])<<8 | std::uint32_t(p[2])<<16 | std::uint32_t(p[3])<<24;
  };
  if (packed.size() < 5) invalid("empty look table");
  const auto size = u32(packed.data());
  if (size < 24 || size > 32*1024*1024) invalid("invalid look-table size");
  std::vector<std::uint8_t> data(size);
  uLongf length = size;
  if (uncompress(data.data(), &length, packed.data()+4, static_cast<uLong>(packed.size()-4)) != Z_OK || length != size)
    invalid("invalid compressed look table");
  const auto version = u32(data.data()+4);
  if (u32(data.data()) != 0 || (version != 1 && version != 2)) invalid("only static HSV look tables v1/v2 are supported");
  DcpHueSatMap map;
  for (unsigned i = 0; i < 3; ++i) map.dims[i] = u32(data.data()+8+i*4);
  if (map.dims[0] < 1 || map.dims[0] > 360 || map.dims[1] < 2 || map.dims[1] > 256 || map.dims[2] < 1 || map.dims[2] > 256)
    invalid("unsupported look-table dimensions");
  const auto count = std::size_t(map.dims[0])*map.dims[1]*map.dims[2];
  const auto end = 20+count*12;
  const auto expected = end+4+(version == 2 ? 16 : 0);
  if (data.size() != expected && data.size() != expected+4) invalid("look-table payload length mismatch");
  map.values.resize(count);
  for (std::size_t i = 0; i < count; ++i) for (unsigned c = 0; c < 3; ++c) {
    const float value = std::bit_cast<float>(u32(data.data()+20+i*12+c*4));
    if (!std::isfinite(value) || (c && value < 0)) invalid("invalid look-table delta");
    map.values[i][c] = value;
  }
  const auto encoding = u32(data.data()+end);
  if (encoding > 1) invalid("unsupported look-table transfer encoding");
  map.srgb_encoding = encoding == 1;
  // Version 2's amount range does not alter the default amount of 1.0.
  if (data.size() == expected+4 && (u32(data.data()+expected) & ~1U)) invalid("unsupported look-table flags");
  return map;
}
#endif
} // namespace

void apply_xmp_look(DcpProfile& profile, const std::filesystem::path& path) {
#if HYPERDR_WITH_CODECS
  if (std::filesystem::file_size(path) > 32*1024*1024) invalid("file exceeds 32 MB");
  const auto bytes = read_binary_file(path);
  const auto root = parse_xml(std::string(bytes.begin(), bytes.end()));
  const auto* desc = find_description(root);
  if (!desc || property(*desc, "PresetType") != "Look") invalid("select a static profile, not an edit preset");
  if (!property(*desc, "ProfileGainTableMap").empty() || !property(*desc, "RGBTables").empty())
    invalid("adaptive gain-table/RGB-table profiles are not supported");
  const auto boolean = [&](const char* key) {
    auto value = property(*desc, key);
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
  };
  if (boolean("ConvertToGrayscale") == "true" || boolean("ConvertToGrayscale") == "1")
    invalid("monochrome profiles are not supported");
  if (boolean("SupportsSceneReferred") == "false" || boolean("SupportsSceneReferred") == "0")
    invalid("profile does not support scene-referred input");
  const auto camera = property(*desc, "CameraProfile");
  if (camera.empty() || camera != profile.name) invalid("requires camera profile " + camera);
  const auto restriction = property(*desc, "CameraModelRestriction");
  if (!restriction.empty() && restriction != profile.camera_model) invalid("camera model restriction does not match");
  static const std::set<std::string> allowed{
      "PresetType","Cluster","UUID","SupportsAmount","SupportsColor","SupportsMonochrome",
      "SupportsHighDynamicRange","SupportsNormalDynamicRange","SupportsSceneReferred","SupportsOutputReferred",
      "CameraModelRestriction","Copyright","ContactInfo","Version","ProcessVersion","ConvertToGrayscale",
      "CameraProfile","LookTable","HasSettings","Name","ShortName","SortName","Group","Description",
      "ToneCurvePV2012","ToneCurvePV2012Red","ToneCurvePV2012Green","ToneCurvePV2012Blue"};
  const auto check = [&](const std::string& key) {
    if (key.starts_with("crs:")) {
      const auto name = key.substr(4);
      if (!allowed.contains(name) && !name.starts_with("Table_")) invalid("unsupported rendering property " + name);
    }
  };
  for (const auto& [key, value] : desc->attributes) check(key);
  for (const auto& child : desc->children) check(child.name);
  for (const auto* channel : {"Red", "Green", "Blue"}) {
    const auto points = curve(*desc, std::string("ToneCurvePV2012")+channel);
    for (const auto& point : points) if (point[0] != point[1]) invalid("non-identity channel curves are not supported");
  }
  const auto id = property(*desc, "LookTable");
  DcpHueSatMap table;
  if (!id.empty()) {
    const auto encoded = property(*desc, "Table_"+id);
    if (encoded.empty()) invalid("referenced look table is not embedded");
    table = look_table(encoded);
  }
  const auto points = curve(*desc, "ToneCurvePV2012");
  if (table.values.empty() && points.empty()) invalid("profile has no supported table or curve");
  std::string name = path_utf8(path.stem());
  if (const auto* node = desc->child("crs:Name")) if (const auto* alt = node->child("rdf:Alt"))
    if (const auto* item = alt->child("rdf:li")) name = trim(item->text);
  profile.xmp_look_table = std::move(table);
  profile.xmp_tone_curve = points;
  profile.xmp_look_name = name;
  profile.xmp_look_sha256 = sha256_file_hex(path);
#else
  (void)profile; (void)path;
  invalid("requires a codec-enabled build");
#endif
}
} // namespace hyperdr
