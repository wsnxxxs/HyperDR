#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include <algorithm>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>

namespace hyperdr {
namespace {
using Bytes = std::vector<std::uint8_t>;
constexpr char iso[] = "urn:iso:std:iso:ts:21496:-1";
[[noreturn]] void invalid(const char* message) { throw std::invalid_argument(message); }
void u16(Bytes& out, std::uint16_t n) { out.push_back(n >> 8); out.push_back(n); }
void u32(Bytes& out, std::uint32_t n) { u16(out, n >> 16); u16(out, n); }
std::uint32_t read(std::span<const std::uint8_t> b, std::size_t p, unsigned n, bool le = false) {
  if (p > b.size() || n > b.size() - p) invalid("truncated JPEG/MPF field");
  std::uint32_t v = 0;
  for (unsigned i = 0; i < n; ++i) v = (v << 8) | b[p + (le ? n - 1 - i : i)];
  return v;
}
bool prefix(const Bytes& b, std::string_view s) {
  return b.size() >= s.size() && std::equal(s.begin(), s.end(), b.begin());
}
bool contains(const Bytes& b, std::string_view s) {
  return std::search(b.begin(), b.end(), s.begin(), s.end()) != b.end();
}
struct Scan { std::vector<JpegAppSegment> apps; std::size_t end{}, insert{}; };
Scan scan(const Bytes& b, std::size_t start) {
  if (read(b, start, 2) != 0xffd8) invalid("missing JPEG SOI");
  Scan out; out.insert = start + 2;
  std::size_t p = start + 2;
  bool entropy = false, leading = true, saw_scan = false, saw_frame = false;
  unsigned frame_components = 0;
  while (p < b.size()) {
    if ((p & 0xffffU) == 0) check_cancelled();
    if (entropy && b[p] != 0xff) { ++p; continue; }
    if (b[p++] != 0xff) invalid("invalid JPEG marker boundary");
    while (p < b.size() && b[p] == 0xff) ++p;
    if (p == b.size()) invalid("truncated JPEG marker");
    const auto m = b[p++];
    if (entropy && (m == 0 || (m >= 0xd0 && m <= 0xd7))) continue;
    entropy = false;
    if (m == 0xd9) {
      if (!saw_scan || !saw_frame) invalid("JPEG contains no frame/scan");
      out.end = p; return out;
    }
    if (m == 0 || m == 0xd8 || (m >= 0xd0 && m <= 0xd7)) invalid("unexpected JPEG marker");
    if (m == 1) { leading = false; continue; }
    const auto length = read(b, p, 2);
    if (length < 2 || length > b.size() - p) invalid("invalid JPEG segment length");
    if (m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc) {
      if (saw_frame || length < 8 || !read(b,p+3,2) || !read(b,p+5,2))
        invalid("invalid JPEG frame header");
      frame_components=read(b,p+7,1);
      if (!frame_components || length != 8 + 3 * frame_components) invalid("invalid JPEG frame components");
      saw_frame=true;
    }
    if (m == 0xda) {
      if (!saw_frame || length < 6) invalid("invalid JPEG scan header");
      const auto components=read(b,p+2,1);
      if (!components || components > frame_components || length != 6 + 2 * components)
        invalid("invalid JPEG scan components");
    }
    const bool app = m >= 0xe0 && m <= 0xef;
    if (app) out.apps.push_back({m, p - 2, Bytes(b.begin() + p + 2, b.begin() + p + length)});
    if (leading && app) out.insert = p + length; else leading = false;
    p += length;
    if (m == 0xda) { saw_scan = true; entropy = true; }
  }
  invalid("missing JPEG EOI");
}
Bytes segment(const Bytes& payload) {
  if (payload.size() > 65533) invalid("JPEG APP2 payload exceeds 65533 bytes");
  Bytes out{0xff, 0xe2}; u16(out, payload.size() + 2);
  out.insert(out.end(), payload.begin(), payload.end()); return out;
}
Bytes iso_segment(const Bytes& metadata) {
  Bytes payload(iso, iso + sizeof(iso));
  payload.insert(payload.end(), metadata.begin(), metadata.end()); return segment(payload);
}
Bytes mpf(std::uint32_t primary_size, std::uint32_t gain_size, std::uint32_t gain_offset) {
  Bytes b{'M','P','F',0,'M','M',0,42}; u32(b, 8); u16(b, 3);
  u16(b, 0xb000); u16(b, 7); u32(b, 4); b.insert(b.end(), {'0','1','0','0'});
  u16(b, 0xb001); u16(b, 4); u32(b, 1); u32(b, 2);
  u16(b, 0xb002); u16(b, 7); u32(b, 32); u32(b, 50);
  u32(b, 0);
  u32(b, 0x30000); u32(b, primary_size); u32(b, 0); u32(b, 0);
  u32(b, 0); u32(b, gain_size); u32(b, gain_offset); u32(b, 0);
  return segment(b);
}
void reject_existing(const Scan& s) {
  for (const auto& app : s.apps) {
    if (prefix(app.payload, std::string_view(iso, sizeof(iso))) ||
        prefix(app.payload, std::string_view("MPF\0", 4)) ||
        contains(app.payload, "http://ns.adobe.com/hdr-gain-map/1.0/") ||
        contains(app.payload, "hdrgm") || contains(app.payload, "Container:Directory"))
      invalid("input JPEG already contains gain-map metadata");
  }
}
}  // namespace

Bytes assemble_gain_map_jpeg(const Bytes& primary, const Bytes& gain, const GainMapMetadata& metadata) {
  check_cancelled();
  if (primary.size() >= (std::uint64_t{1} << 32) || gain.size() >= (std::uint64_t{1} << 32))
    invalid("gain-map JPEG must be smaller than 4 GiB");
  const auto p = scan(primary, 0), g = scan(gain, 0);
  if (p.end != primary.size() || g.end != gain.size()) invalid("trailing input JPEG bytes");
  reject_existing(p); reject_existing(g);
  if (!g.apps.empty()) invalid("gain JPEG must not contain APP segments");
  auto payload = serialize_tmap_payload(metadata);
  payload.erase(payload.begin());  // HEIF ToneMapImage version is not part of ISO metadata.
  const auto version = iso_segment({0,0,0,0});
  const auto gain_iso = iso_segment(payload);
  const std::uint64_t psize = primary.size() + version.size() + mpf(0,0,0).size();
  const std::uint64_t gsize = gain.size() + gain_iso.size();
  if (psize + gsize >= (std::uint64_t{1} << 32)) invalid("gain-map JPEG must be smaller than 4 GiB");
  // TIFF starts after the APP2 marker, length, and MPF signature.
  const auto tiff = p.insert + version.size() + 8;
  const auto index = mpf(psize, gsize, psize - tiff);
  Bytes out; out.reserve(psize + gsize);
  out.insert(out.end(), primary.begin(), primary.begin() + p.insert);
  out.insert(out.end(), version.begin(), version.end());
  out.insert(out.end(), index.begin(), index.end());
  out.insert(out.end(), primary.begin() + p.insert, primary.end());
  out.insert(out.end(), gain.begin(), gain.begin() + 2);
  out.insert(out.end(), gain_iso.begin(), gain_iso.end());
  out.insert(out.end(), gain.begin() + 2, gain.end());
  check_cancelled(); return out;
}

GainMapJpeg parse_gain_map_jpeg(const Bytes& bytes) {
  if (bytes.size() >= (std::uint64_t{1} << 32)) invalid("gain-map JPEG must be smaller than 4 GiB");
  GainMapJpeg out;
  auto primary = scan(bytes, 0);
  out.primary_size = primary.end;
  const JpegAppSegment* index = nullptr;
  for (const auto& app : primary.apps) {
    if (app.marker == 0xe2 && prefix(app.payload, std::string_view("MPF\0", 4))) {
      ++out.mpf_count; index = &app;
    }
    if (app.marker == 0xe2 && prefix(app.payload, std::string_view(iso, sizeof(iso)))) {
      ++out.primary_iso_count;
      if (app.payload.size() != sizeof(iso) + 4) invalid("invalid primary ISO version segment");
      out.minimum_version = read(app.payload, sizeof(iso), 2);
      out.writer_version = read(app.payload, sizeof(iso) + 2, 2);
      if (out.minimum_version != 0 || out.writer_version != 0) invalid("unsupported JPEG ISO version");
    }
  }
  if (out.mpf_count != 1 || !index) invalid("gain-map JPEG requires one MPF index");
  const auto t = std::span<const std::uint8_t>(index->payload).subspan(4);
  const auto endian = read(t, 0, 2);
  if (endian != 0x4d4d && endian != 0x4949) invalid("invalid MPF byte order");
  const bool le = endian == 0x4949;
  auto r = [&](std::size_t pos, unsigned n) { return read(t, pos, n, le); };
  if (r(2, 2) != 42) invalid("invalid MPF TIFF header");
  const auto ifd = r(4, 4); const auto count = r(ifd, 2);
  if (ifd > t.size() || t.size() - ifd < 2 || count > (t.size() - ifd - 2) / 12) invalid("truncated MPF IFD");
  if (r(ifd + 2 + count * 12, 4) != 0) invalid("multiple MPF IFDs are unsupported");
  bool version = false, number = false, entries = false;
  for (unsigned i = 0; i < count; ++i) {
    const std::size_t pos = ifd + 2 + i * 12;
    const auto tag = r(pos, 2), type = r(pos + 2, 2), n = r(pos + 4, 4), value = r(pos + 8, 4);
    if (tag == 0xb000) {
      if (version || type != 7 || n != 4 || read(t, pos + 8, 4) != 0x30313030) invalid("invalid MPF version");
      version = true;
    } else if (tag == 0xb001) {
      if (number || type != 4 || n != 1 || value != 2) invalid("MPF must describe two images");
      number = true;
    } else if (tag == 0xb002) {
      if (entries || type != 7 || n != 32 || value < ifd + 2 + count * 12 + 4) invalid("invalid MPF entry table");
      entries = true;
      for (unsigned j = 0; j < 2; ++j) {
        const std::uint64_t p = static_cast<std::uint64_t>(value) + j * 16;
        out.entries[j] = {r(p, 4), r(p + 4, 4), r(p + 8, 4)};
        if (r(p + 12, 2) || r(p + 14, 2)) invalid("dependent MPF images are unsupported");
      }
    }
  }
  if (!version || !number || !entries || out.entries[0].offset != 0 ||
      out.entries[0].size != primary.end || (out.entries[0].attributes & 0xffffff) != 0x30000 ||
      (out.entries[1].attributes & 0xffffff) != 0 ||
      ((out.entries[0].attributes | out.entries[1].attributes) & 0x07000000U) != 0) invalid("invalid MPF primary/gain entries");
  const std::uint64_t offset = static_cast<std::uint64_t>(index->offset) + 8 + out.entries[1].offset;
  if (offset != primary.end || offset > bytes.size() || out.entries[1].size != bytes.size() - offset)
    invalid("MPF gain range does not match JPEG bytes");
  auto gain = scan(bytes, offset);
  if (gain.end != bytes.size()) invalid("trailing gain-map JPEG data");
  out.gain_offset = offset; out.gain_size = out.entries[1].size;
  for (const auto& app : gain.apps) {
    if (app.marker == 0xe2 && prefix(app.payload, std::string_view("MPF\0", 4)))
      invalid("unexpected MPF index in gain image");
    if (app.marker == 0xe2 && prefix(app.payload, std::string_view(iso, sizeof(iso)))) {
      ++out.gain_iso_count;
      Bytes payload{0}; payload.insert(payload.end(), app.payload.begin() + sizeof(iso), app.payload.end());
      out.metadata = parse_tmap_payload(payload);
    }
  }
  if (out.primary_iso_count != 1 || out.gain_iso_count != 1) invalid("gain-map JPEG requires exactly one ISO segment per image");
  out.app_segments = {std::move(primary.apps), std::move(gain.apps)};
  for (const auto& apps : out.app_segments) for (const auto& app : apps) {
    out.has_hdrgm |= contains(app.payload, "hdrgm") || contains(app.payload, "http://ns.adobe.com/hdr-gain-map/1.0/");
    out.has_container_directory |= contains(app.payload, "Container:Directory") ||
        contains(app.payload, "http://ns.google.com/photos/1.0/container/");
  }
  return out;
}
}  // namespace hyperdr
