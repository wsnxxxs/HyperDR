#include "hyperdr/container/exif.hpp"

#include "hyperdr/foundation/version.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <sstream>
#include <limits>
#include <stdexcept>
#include <utility>

namespace hyperdr {
namespace {

void u16le(std::vector<std::uint8_t>& out, std::uint16_t v) {
  out.push_back(static_cast<std::uint8_t>(v));
  out.push_back(static_cast<std::uint8_t>(v >> 8));
}
void u32le(std::vector<std::uint8_t>& out, std::uint32_t v) {
  out.push_back(static_cast<std::uint8_t>(v));
  out.push_back(static_cast<std::uint8_t>(v >> 8));
  out.push_back(static_cast<std::uint8_t>(v >> 16));
  out.push_back(static_cast<std::uint8_t>(v >> 24));
}
void set_u32le(std::vector<std::uint8_t>& out, std::size_t pos, std::uint32_t v) {
  for (unsigned i = 0; i < 4; ++i) out.at(pos + i) = static_cast<std::uint8_t>(v >> (i * 8));
}
std::string xml_escape(const std::string& input) {
  std::string out;
  for (const char c : input) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '\"': out += "&quot;"; break;
      case '\'': out += "&apos;"; break;
      default: out += c; break;
    }
  }
  return out;
}

struct Entry {
  std::uint16_t tag;
  std::uint16_t type;
  std::uint32_t count;
  std::vector<std::uint8_t> value;
};

Entry ascii(std::uint16_t tag, std::string value) {
  value.push_back('\0');
  return {tag, 2, static_cast<std::uint32_t>(value.size()),
          std::vector<std::uint8_t>(value.begin(), value.end())};
}
Entry short_value(std::uint16_t tag, std::uint16_t value) {
  return {tag, 3, 1, {static_cast<std::uint8_t>(value), static_cast<std::uint8_t>(value >> 8)}};
}
Entry rational_value(std::uint16_t tag, double value) {
  constexpr std::uint32_t denominator = 100000;
  const auto numerator = static_cast<std::uint32_t>(std::max(0.0, std::round(value * denominator)));
  std::vector<std::uint8_t> bytes;
  u32le(bytes, numerator);
  u32le(bytes, denominator);
  return {tag, 5, 1, std::move(bytes)};
}

Entry byte_array(std::uint16_t tag, std::vector<std::uint8_t> bytes) {
  const auto count = static_cast<std::uint32_t>(bytes.size());
  return {tag, 1, count, std::move(bytes)};
}

Entry rational_array(std::uint16_t tag,
                     const std::vector<std::pair<std::uint32_t, std::uint32_t>>& values) {
  std::vector<std::uint8_t> bytes;
  for (const auto& [numerator, denominator] : values) {
    u32le(bytes, numerator);
    u32le(bytes, denominator);
  }
  return {tag, 5, static_cast<std::uint32_t>(values.size()), std::move(bytes)};
}

// Exif stores a coordinate as degrees, minutes and seconds rationals with the
// hemisphere carried separately, so the sign is dropped here on purpose.
std::vector<std::pair<std::uint32_t, std::uint32_t>> to_dms(double degrees) {
  double remainder = std::abs(degrees);
  const auto whole_degrees = static_cast<std::uint32_t>(std::floor(remainder));
  remainder = (remainder - whole_degrees) * 60.0;
  const auto whole_minutes = static_cast<std::uint32_t>(std::floor(remainder));
  const double seconds = (remainder - whole_minutes) * 60.0;
  constexpr std::uint32_t kSecondsScale = 10000;
  const auto scaled_seconds = static_cast<std::uint32_t>(
      std::min(std::round(seconds * kSecondsScale),
               static_cast<double>(std::numeric_limits<std::uint32_t>::max())));
  return {{whole_degrees, 1}, {whole_minutes, 1}, {scaled_seconds, kSecondsScale}};
}

std::vector<std::uint8_t> build_ifd(const std::vector<Entry>& entries, std::uint32_t ifd_offset,
                                    std::vector<std::uint8_t>& trailing) {
  std::vector<std::uint8_t> out;
  u16le(out, static_cast<std::uint16_t>(entries.size()));
  const std::uint32_t data_start = ifd_offset + 2 + static_cast<std::uint32_t>(entries.size()) * 12 + 4;
  for (const auto& entry : entries) {
    const auto entry_start = out.size();
    u16le(out, entry.tag);
    u16le(out, entry.type);
    u32le(out, entry.count);
    if (entry.value.size() <= 4) {
      out.insert(out.end(), entry.value.begin(), entry.value.end());
      out.resize(entry_start + 12, 0);
    } else {
      u32le(out, data_start + static_cast<std::uint32_t>(trailing.size()));
      trailing.insert(trailing.end(), entry.value.begin(), entry.value.end());
      if ((trailing.size() & 1U) != 0) trailing.push_back(0);
    }
  }
  u32le(out, 0);
  return out;
}

}  // namespace

std::vector<std::uint8_t> make_minimal_exif(const PhotoMetadata& m) {
  // libheif expects a TIFF payload; it prepends the HEIF Exif item offset field itself.
  std::vector<Entry> exif_entries;
  if (!m.date_time.empty()) exif_entries.push_back(ascii(0x9003, m.date_time));
  if (m.exposure_seconds > 0) exif_entries.push_back(rational_value(0x829A, m.exposure_seconds));
  if (m.aperture > 0) exif_entries.push_back(rational_value(0x829D, m.aperture));
  // Exif PhotographicSensitivity is SHORT. Exif requires 65535 as the
  // sentinel when the real sensitivity is larger; XMP below retains the value.
  if (m.iso > 0) {
    exif_entries.push_back(short_value(
        0x8827, static_cast<std::uint16_t>(std::min<std::uint32_t>(m.iso, 65535U))));
  }
  if (m.focal_length_mm > 0) exif_entries.push_back(rational_value(0x920A, m.focal_length_mm));
  if (!m.lens.empty()) exif_entries.push_back(ascii(0xA434, m.lens));
  if (!m.lens_make.empty()) exif_entries.push_back(ascii(0xA433, m.lens_make));
  if (m.focal_length_35mm > 0) {
    exif_entries.push_back(short_value(
        0xA405, static_cast<std::uint16_t>(std::min(m.focal_length_35mm, 65535.0))));
  }

  std::vector<Entry> ifd0_entries;
  if (!m.make.empty()) ifd0_entries.push_back(ascii(0x010F, m.make));
  if (!m.model.empty()) ifd0_entries.push_back(ascii(0x0110, m.model));
  ifd0_entries.push_back(short_value(0x0112, std::clamp<std::uint16_t>(m.orientation, 1, 8)));
  if (!m.date_time.empty()) ifd0_entries.push_back(ascii(0x0132, m.date_time));
  if (!m.artist.empty()) ifd0_entries.push_back(ascii(0x013B, m.artist));
  if (!m.copyright.empty()) ifd0_entries.push_back(ascii(0x8298, m.copyright));
  ifd0_entries.push_back(ascii(0x0131, m.software.empty()
                                           ? std::string("HyperDR ") + kVersion
                                           : m.software));

  // GPS lives in its own IFD referenced from IFD0, so it is only built when the
  // camera actually recorded a fix. Fabricating a location would be worse than
  // omitting one.
  std::vector<Entry> gps_entries;
  if (m.gps) {
    gps_entries.push_back(byte_array(0x0000, {2, 3, 0, 0}));
    gps_entries.push_back(ascii(0x0001, m.gps->latitude_degrees < 0 ? "S" : "N"));
    gps_entries.push_back(rational_array(0x0002, to_dms(m.gps->latitude_degrees)));
    gps_entries.push_back(ascii(0x0003, m.gps->longitude_degrees < 0 ? "W" : "E"));
    gps_entries.push_back(rational_array(0x0004, to_dms(m.gps->longitude_degrees)));
    if (m.gps->altitude_metres) {
      const double altitude = *m.gps->altitude_metres;
      gps_entries.push_back(byte_array(0x0005, {altitude < 0 ? std::uint8_t{1}
                                                             : std::uint8_t{0}}));
      gps_entries.push_back(rational_value(0x0006, std::abs(altitude)));
    }
  }

  // Placeholders for the sub-IFD pointers; patched once IFD0's layout is known.
  ifd0_entries.push_back(Entry{0x8769, 4, 1, {0, 0, 0, 0}});
  if (!gps_entries.empty()) ifd0_entries.push_back(Entry{0x8825, 4, 1, {0, 0, 0, 0}});
  const auto by_tag = [](const Entry& a, const Entry& b) { return a.tag < b.tag; };
  std::sort(ifd0_entries.begin(), ifd0_entries.end(), by_tag);
  std::sort(exif_entries.begin(), exif_entries.end(), by_tag);
  std::sort(gps_entries.begin(), gps_entries.end(), by_tag);

  std::vector<std::uint8_t> ifd0_trailing;
  auto ifd0 = build_ifd(ifd0_entries, 8, ifd0_trailing);
  const auto exif_offset = static_cast<std::uint32_t>(8 + ifd0.size() + ifd0_trailing.size());
  std::vector<std::uint8_t> exif_trailing;
  auto exif_ifd = build_ifd(exif_entries, exif_offset, exif_trailing);
  const auto gps_offset =
      static_cast<std::uint32_t>(exif_offset + exif_ifd.size() + exif_trailing.size());
  std::vector<std::uint8_t> gps_trailing;
  auto gps_ifd = gps_entries.empty() ? std::vector<std::uint8_t>{}
                                     : build_ifd(gps_entries, gps_offset, gps_trailing);
  for (std::size_t i = 0; i < ifd0_entries.size(); ++i) {
    if (ifd0_entries[i].tag == 0x8769) set_u32le(ifd0, 2 + i * 12 + 8, exif_offset);
    if (ifd0_entries[i].tag == 0x8825) set_u32le(ifd0, 2 + i * 12 + 8, gps_offset);
  }

  std::vector<std::uint8_t> out{'I', 'I'};
  u16le(out, 42);
  u32le(out, 8);
  out.insert(out.end(), ifd0.begin(), ifd0.end());
  out.insert(out.end(), ifd0_trailing.begin(), ifd0_trailing.end());
  out.insert(out.end(), exif_ifd.begin(), exif_ifd.end());
  out.insert(out.end(), exif_trailing.begin(), exif_trailing.end());
  out.insert(out.end(), gps_ifd.begin(), gps_ifd.end());
  out.insert(out.end(), gps_trailing.begin(), gps_trailing.end());
  return out;
}

std::string make_xmp(const PhotoMetadata& m, float headroom_stops) {
  std::ostringstream out;
  out << "<?xpacket begin='\xEF\xBB\xBF'?>\n"
      << "<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'>"
      << "<rdf:Description xmlns:tiff='http://ns.adobe.com/tiff/1.0/' "
      << "xmlns:exif='http://ns.adobe.com/exif/1.0/' "
      << "xmlns:aux='http://ns.adobe.com/exif/1.0/aux/' "
      << "xmlns:xmp='http://ns.adobe.com/xap/1.0/' "
      << "xmlns:dc='http://purl.org/dc/elements/1.1/' "
      << "xmlns:hyperdr='https://github.com/openai/hyperdr/1.0/' "
      << "tiff:Make='" << xml_escape(m.make) << "' tiff:Model='" << xml_escape(m.model) << "' "
      << "aux:Lens='" << xml_escape(m.lens) << "' "
      << "xmp:CreatorTool='"
      << xml_escape(m.software.empty() ? std::string("HyperDR ") + kVersion
                                       : m.software)
      << "' "
      << "hyperdr:AdaptiveHDR='ISO-21496-1:2025' hyperdr:HeadroomStops='"
      << std::fixed << std::setprecision(5) << headroom_stops << "'>";
  if (m.iso > 0) {
    out << "<exif:ISOSpeedRatings><rdf:Seq><rdf:li>" << m.iso
        << "</rdf:li></rdf:Seq></exif:ISOSpeedRatings>";
  }
  if (!m.artist.empty()) {
    out << "<dc:creator><rdf:Seq><rdf:li>" << xml_escape(m.artist)
        << "</rdf:li></rdf:Seq></dc:creator>";
  }
  if (!m.copyright.empty()) {
    out << "<dc:rights><rdf:Alt><rdf:li xml:lang='x-default'>"
        << xml_escape(m.copyright) << "</rdf:li></rdf:Alt></dc:rights>";
  }
  if (m.gps) {
    out << "<exif:GPSLatitude>" << std::fixed << std::setprecision(7)
        << std::abs(m.gps->latitude_degrees) << (m.gps->latitude_degrees < 0 ? "S" : "N")
        << "</exif:GPSLatitude><exif:GPSLongitude>"
        << std::abs(m.gps->longitude_degrees)
        << (m.gps->longitude_degrees < 0 ? "W" : "E") << "</exif:GPSLongitude>";
  }
  out << "</rdf:Description></rdf:RDF></x:xmpmeta>\n"
      << "<?xpacket end='w'?>";
  return out.str();
}

namespace {

// --- Reading a TIFF/Exif block ---------------------------------------------
//
// One bounds-checked walker, shared by everything that reads Exif. These are
// attacker-controlled bytes: every offset is computed in 64 bits and compared
// against the block size before it is used, and an entry that does not add up
// is reported as absent rather than guessed at. Nothing here throws, so a
// malformed block costs the caller a field, not the conversion.

struct TiffBlock {
  const std::uint8_t* data{};
  std::size_t size{};
  bool big_endian{};
  std::uint64_t ifd0{};

  [[nodiscard]] std::uint16_t u16(std::size_t offset) const {
    return big_endian
               ? static_cast<std::uint16_t>((data[offset] << 8) | data[offset + 1])
               : static_cast<std::uint16_t>(data[offset] | (data[offset + 1] << 8));
  }
  [[nodiscard]] std::uint32_t u32(std::size_t offset) const {
    const auto a = static_cast<std::uint32_t>(data[offset]);
    const auto b = static_cast<std::uint32_t>(data[offset + 1]);
    const auto c = static_cast<std::uint32_t>(data[offset + 2]);
    const auto d = static_cast<std::uint32_t>(data[offset + 3]);
    return big_endian ? (a << 24) | (b << 16) | (c << 8) | d
                      : (d << 24) | (c << 16) | (b << 8) | a;
  }
};

struct TiffEntry {
  std::uint16_t type{};
  std::uint32_t count{};
  // Where the values actually are: inline in the entry when they fit in the
  // four-byte value field, otherwise at the offset that field holds.
  std::uint64_t value_offset{};
};

std::size_t tiff_type_size(std::uint16_t type) {
  switch (type) {
    case 1: case 2: case 6: case 7: return 1;  // BYTE, ASCII, SBYTE, UNDEFINED
    case 3: case 8: return 2;                  // SHORT, SSHORT
    case 4: case 9: case 11: return 4;         // LONG, SLONG, FLOAT
    case 5: case 10: case 12: return 8;        // RATIONAL, SRATIONAL, DOUBLE
    default: return 0;
  }
}

std::optional<TiffBlock> open_tiff(const std::uint8_t* data, std::size_t size) {
  if (data == nullptr) return std::nullopt;
  // A HEIF Exif item is prefixed with a four-byte offset to the TIFF header,
  // and some writers leave the JPEG "Exif\0\0" signature in place even when the
  // caller was supposed to strip it. Rather than teach every caller which
  // preamble its container uses, find the byte-order mark within a short
  // window; a block with no header in the first 16 bytes is not Exif.
  std::size_t start = 0;
  while (start + 8 <= size && start <= 16) {
    const bool motorola = data[start] == 'M' && data[start + 1] == 'M';
    const bool intel = data[start] == 'I' && data[start + 1] == 'I';
    if (motorola || intel) {
      TiffBlock block{data + start, size - start, motorola, 0};
      if (block.u16(2) != 42) return std::nullopt;
      block.ifd0 = block.u32(4);
      // IFD0 needs at least a two-byte entry count.
      if (block.ifd0 + 2 > block.size) return std::nullopt;
      return block;
    }
    ++start;
  }
  return std::nullopt;
}

std::optional<TiffEntry> find_entry(const TiffBlock& block, std::uint64_t ifd,
                                    std::uint16_t tag) {
  if (ifd + 2 > block.size) return std::nullopt;
  const std::uint32_t entries = block.u16(static_cast<std::size_t>(ifd));
  if (ifd + 2 + static_cast<std::uint64_t>(entries) * 12 > block.size) {
    return std::nullopt;
  }
  for (std::uint32_t i = 0; i < entries; ++i) {
    const auto at = static_cast<std::size_t>(ifd + 2 + static_cast<std::uint64_t>(i) * 12);
    if (block.u16(at) != tag) continue;
    TiffEntry entry;
    entry.type = block.u16(at + 2);
    entry.count = block.u32(at + 4);
    const std::size_t unit = tiff_type_size(entry.type);
    if (unit == 0 || entry.count == 0) return std::nullopt;
    const std::uint64_t bytes = static_cast<std::uint64_t>(unit) * entry.count;
    entry.value_offset = bytes <= 4 ? at + 8 : block.u32(at + 8);
    if (entry.value_offset + bytes > block.size) return std::nullopt;
    return entry;
  }
  return std::nullopt;
}

std::optional<std::uint32_t> read_unsigned(const TiffBlock& block, std::uint64_t ifd,
                                           std::uint16_t tag) {
  const auto entry = find_entry(block, ifd, tag);
  if (!entry) return std::nullopt;
  const auto at = static_cast<std::size_t>(entry->value_offset);
  if (entry->type == 3) return block.u16(at);
  if (entry->type == 4) return block.u32(at);
  return std::nullopt;
}

// Exif defines Orientation as a single SHORT, and this stays stricter than
// read_unsigned on purpose: a tag of another type in that slot is a malformed
// file, and quietly rotating a photograph on the strength of it is worse than
// leaving it alone.
std::optional<std::uint16_t> read_orientation(const TiffBlock& block,
                                              std::uint64_t ifd) {
  const auto entry = find_entry(block, ifd, 0x0112);
  if (!entry || entry->type != 3 || entry->count != 1) return std::nullopt;
  const auto value = block.u16(static_cast<std::size_t>(entry->value_offset));
  if (value < 1 || value > 8) return std::nullopt;
  return value;
}

std::optional<double> read_rational(const TiffBlock& block, std::uint64_t ifd,
                                    std::uint16_t tag) {
  const auto entry = find_entry(block, ifd, tag);
  if (!entry || (entry->type != 5 && entry->type != 10)) return std::nullopt;
  const auto at = static_cast<std::size_t>(entry->value_offset);
  const auto numerator = block.u32(at);
  const auto denominator = block.u32(at + 4);
  if (denominator == 0) return std::nullopt;
  if (entry->type == 10) {
    return static_cast<double>(static_cast<std::int32_t>(numerator)) /
           static_cast<double>(static_cast<std::int32_t>(denominator));
  }
  return static_cast<double>(numerator) / static_cast<double>(denominator);
}

std::string read_ascii(const TiffBlock& block, std::uint64_t ifd, std::uint16_t tag) {
  const auto entry = find_entry(block, ifd, tag);
  if (!entry || entry->type != 2) return {};
  const auto at = static_cast<std::size_t>(entry->value_offset);
  // A conforming value is NUL-terminated; a truncated one simply ends. Cap the
  // length so a hostile 4 GB count cannot turn a tag into an allocation.
  constexpr std::uint32_t kMaxAscii = 512;
  const std::uint32_t count = std::min(entry->count, kMaxAscii);
  std::string value(reinterpret_cast<const char*>(block.data + at), count);
  const auto terminator = value.find('\0');
  if (terminator != std::string::npos) value.resize(terminator);
  while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) {
    value.pop_back();
  }
  return value;
}

}  // namespace

ExifRead read_exif(const std::uint8_t* data, std::size_t size) {
  ExifRead result;
  const auto block = open_tiff(data, size);
  if (!block) return result;

  auto& m = result.metadata;
  m.make = read_ascii(*block, block->ifd0, 0x010F);
  m.model = read_ascii(*block, block->ifd0, 0x0110);
  m.date_time = read_ascii(*block, block->ifd0, 0x0132);
  m.artist = read_ascii(*block, block->ifd0, 0x013B);
  m.copyright = read_ascii(*block, block->ifd0, 0x8298);
  if (const auto orientation = read_orientation(*block, block->ifd0)) {
    result.orientation = *orientation;
    m.orientation = *orientation;
  }

  // Capture settings live in the Exif sub-IFD that IFD0 points at. No pointer
  // means no capture settings, which is a normal state for a rendered file.
  const auto exif_ifd = read_unsigned(*block, block->ifd0, 0x8769);
  if (!exif_ifd) return result;
  const std::uint64_t sub = *exif_ifd;

  // ISO is SHORT in most files but LONG in a few; PhotographicSensitivity
  // (0x8827) is the tag both spellings use.
  if (const auto iso = read_unsigned(*block, sub, 0x8827)) m.iso = *iso;
  if (const auto seconds = read_rational(*block, sub, 0x829A)) {
    if (*seconds > 0.0) m.exposure_seconds = *seconds;
  }
  if (const auto aperture = read_rational(*block, sub, 0x829D)) {
    if (*aperture > 0.0) m.aperture = *aperture;
  }
  if (const auto focal = read_rational(*block, sub, 0x920A)) {
    if (*focal > 0.0) m.focal_length_mm = *focal;
  }
  if (const auto focal35 = read_unsigned(*block, sub, 0xA405)) {
    m.focal_length_35mm = static_cast<double>(*focal35);
  }
  m.lens = read_ascii(*block, sub, 0xA434);
  m.lens_make = read_ascii(*block, sub, 0xA433);
  return result;
}

std::optional<std::uint16_t> read_exif_orientation(const std::uint8_t* data,
                                                   std::size_t size) {
  return read_exif(data, size).orientation;
}

}  // namespace hyperdr

