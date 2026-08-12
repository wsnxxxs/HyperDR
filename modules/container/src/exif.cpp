#include "hyperdr/container/exif.hpp"

#include "hyperdr/foundation/version.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <iomanip>
#include <limits>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string_view>
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

struct TiffView {
  const std::uint8_t* data{};
  std::size_t size{};
  bool big_endian{};

  [[nodiscard]] bool contains(std::uint64_t offset, std::uint64_t length) const {
    return offset <= size && length <= size - static_cast<std::size_t>(offset);
  }

  [[nodiscard]] std::optional<std::uint16_t> u16(std::uint64_t offset) const {
    if (!contains(offset, 2)) return std::nullopt;
    const auto at = static_cast<std::size_t>(offset);
    return big_endian
               ? static_cast<std::uint16_t>((data[at] << 8) | data[at + 1])
               : static_cast<std::uint16_t>(data[at] | (data[at + 1] << 8));
  }

  [[nodiscard]] std::optional<std::uint32_t> u32(std::uint64_t offset) const {
    if (!contains(offset, 4)) return std::nullopt;
    const auto at = static_cast<std::size_t>(offset);
    const auto a = static_cast<std::uint32_t>(data[at]);
    const auto b = static_cast<std::uint32_t>(data[at + 1]);
    const auto c = static_cast<std::uint32_t>(data[at + 2]);
    const auto d = static_cast<std::uint32_t>(data[at + 3]);
    return big_endian ? (a << 24) | (b << 16) | (c << 8) | d
                      : (d << 24) | (c << 16) | (b << 8) | a;
  }
};

struct TiffEntry {
  std::uint16_t type{};
  std::uint32_t count{};
  std::uint64_t bytes_offset{};
  std::uint64_t bytes_size{};
};

std::optional<std::size_t> tiff_start(const std::uint8_t* data,
                                      std::size_t size) {
  if (data == nullptr) return std::nullopt;
  const auto is_tiff = [&](std::size_t at) {
    if (at > size || size - at < 4) return false;
    return (data[at] == 'I' && data[at + 1] == 'I' && data[at + 2] == 42 &&
            data[at + 3] == 0) ||
           (data[at] == 'M' && data[at + 1] == 'M' && data[at + 2] == 0 &&
            data[at + 3] == 42);
  };
  if (is_tiff(0)) return 0;
  if (size >= 6 && std::memcmp(data, "Exif\0\0", 6) == 0 && is_tiff(6)) {
    return 6;
  }
  if (size >= 4) {
    const std::uint64_t relative =
        (static_cast<std::uint64_t>(data[0]) << 24) |
        (static_cast<std::uint64_t>(data[1]) << 16) |
        (static_cast<std::uint64_t>(data[2]) << 8) | data[3];
    // ISO BMFF Exif items store the TIFF offset relative to the byte after the
    // offset field. libheif normally emits zero, but accept a non-zero prefix.
    if (relative <= size - 4 && is_tiff(4 + static_cast<std::size_t>(relative))) {
      return 4 + static_cast<std::size_t>(relative);
    }
  }
  return std::nullopt;
}

std::optional<TiffEntry> find_entry(const TiffView& tiff,
                                    std::uint32_t ifd_offset,
                                    std::uint16_t wanted_tag) {
  const auto count = tiff.u16(ifd_offset);
  if (!count) return std::nullopt;
  const std::uint64_t table_size = 2 + static_cast<std::uint64_t>(*count) * 12 + 4;
  if (!tiff.contains(ifd_offset, table_size)) return std::nullopt;
  constexpr std::array<std::uint8_t, 13> type_sizes{
      0, 1, 1, 2, 4, 8, 1, 1, 2, 4, 8, 4, 8};
  for (std::uint32_t index = 0; index < *count; ++index) {
    const std::uint64_t at =
        static_cast<std::uint64_t>(ifd_offset) + 2 + index * 12;
    const auto tag = tiff.u16(at);
    if (!tag || *tag != wanted_tag) continue;
    const auto type = tiff.u16(at + 2);
    const auto values = tiff.u32(at + 4);
    if (!type || !values || *type >= type_sizes.size() ||
        type_sizes[*type] == 0) {
      return std::nullopt;
    }
    const std::uint64_t bytes =
        static_cast<std::uint64_t>(*values) * type_sizes[*type];
    if (*values != 0 && bytes / type_sizes[*type] != *values) {
      return std::nullopt;
    }
    std::uint64_t value_offset = at + 8;
    if (bytes > 4) {
      const auto offset = tiff.u32(at + 8);
      if (!offset) return std::nullopt;
      value_offset = *offset;
    }
    if (!tiff.contains(value_offset, bytes)) return std::nullopt;
    return TiffEntry{*type, *values, value_offset, bytes};
  }
  return std::nullopt;
}

std::string entry_ascii(const TiffView& tiff,
                        const std::optional<TiffEntry>& entry) {
  if (!entry || entry->type != 2 || entry->bytes_size == 0) return {};
  const auto* begin = reinterpret_cast<const char*>(tiff.data + entry->bytes_offset);
  std::size_t length = static_cast<std::size_t>(entry->bytes_size);
  while (length != 0 && begin[length - 1] == '\0') --length;
  return std::string(begin, begin + length);
}

std::optional<std::uint32_t> entry_unsigned(
    const TiffView& tiff, const std::optional<TiffEntry>& entry,
    std::size_t index = 0) {
  if (!entry || index >= entry->count) return std::nullopt;
  if (entry->type == 1) {
    return tiff.data[entry->bytes_offset + index];
  }
  if (entry->type == 3) return tiff.u16(entry->bytes_offset + index * 2);
  if (entry->type == 4) return tiff.u32(entry->bytes_offset + index * 4);
  return std::nullopt;
}

std::optional<double> entry_rational(
    const TiffView& tiff, const std::optional<TiffEntry>& entry,
    std::size_t index = 0) {
  if (!entry || entry->type != 5 || index >= entry->count) return std::nullopt;
  const auto numerator = tiff.u32(entry->bytes_offset + index * 8);
  const auto denominator = tiff.u32(entry->bytes_offset + index * 8 + 4);
  if (!numerator || !denominator || *denominator == 0) return std::nullopt;
  return static_cast<double>(*numerator) / *denominator;
}

std::optional<double> gps_coordinate(const TiffView& tiff,
                                     std::uint32_t gps_ifd,
                                     std::uint16_t value_tag,
                                     std::uint16_t ref_tag) {
  const auto values = find_entry(tiff, gps_ifd, value_tag);
  if (!values || values->type != 5 || values->count < 3) return std::nullopt;
  const auto degrees = entry_rational(tiff, values, 0);
  const auto minutes = entry_rational(tiff, values, 1);
  const auto seconds = entry_rational(tiff, values, 2);
  if (!degrees || !minutes || !seconds) return std::nullopt;
  double coordinate = *degrees + *minutes / 60.0 + *seconds / 3600.0;
  const auto ref = entry_ascii(tiff, find_entry(tiff, gps_ifd, ref_tag));
  if (ref == "S" || ref == "s" || ref == "W" || ref == "w") {
    coordinate = -coordinate;
  }
  return coordinate;
}

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

std::string make_xmp(const PhotoMetadata& m, float headroom_stops,
                     bool has_gain_map) {
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
      << "' ";
  if (has_gain_map) {
    out << "hyperdr:AdaptiveHDR='ISO-21496-1:2025' hyperdr:HeadroomStops='";
  } else {
    out << "hyperdr:RenderedHDR='true' hyperdr:RenderedHeadroomStops='";
  }
  out << std::fixed << std::setprecision(5) << headroom_stops << "'>";
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

std::optional<PhotoMetadata> read_photo_metadata(const std::uint8_t* data,
                                                 std::size_t size) {
  const auto start = tiff_start(data, size);
  if (!start || *start > size) return std::nullopt;
  TiffView tiff{data + *start, size - *start, false};
  if (tiff.size < 8) return std::nullopt;
  if (tiff.data[0] == 'M' && tiff.data[1] == 'M') {
    tiff.big_endian = true;
  } else if (!(tiff.data[0] == 'I' && tiff.data[1] == 'I')) {
    return std::nullopt;
  }
  const auto version = tiff.u16(2);
  const auto ifd0 = tiff.u32(4);
  if (!version || *version != 42 || !ifd0 || !tiff.contains(*ifd0, 2)) {
    return std::nullopt;
  }

  PhotoMetadata metadata;
  metadata.make = entry_ascii(tiff, find_entry(tiff, *ifd0, 0x010F));
  metadata.model = entry_ascii(tiff, find_entry(tiff, *ifd0, 0x0110));
  metadata.artist = entry_ascii(tiff, find_entry(tiff, *ifd0, 0x013B));
  metadata.copyright = entry_ascii(tiff, find_entry(tiff, *ifd0, 0x8298));
  metadata.date_time = entry_ascii(tiff, find_entry(tiff, *ifd0, 0x0132));
  if (const auto orientation =
          entry_unsigned(tiff, find_entry(tiff, *ifd0, 0x0112));
      orientation && *orientation >= 1 && *orientation <= 8) {
    metadata.orientation = static_cast<std::uint16_t>(*orientation);
  }

  if (const auto exif_ifd =
          entry_unsigned(tiff, find_entry(tiff, *ifd0, 0x8769));
      exif_ifd && tiff.contains(*exif_ifd, 2)) {
    const auto original =
        entry_ascii(tiff, find_entry(tiff, *exif_ifd, 0x9003));
    if (!original.empty()) metadata.date_time = original;
    metadata.lens =
        entry_ascii(tiff, find_entry(tiff, *exif_ifd, 0xA434));
    metadata.lens_make =
        entry_ascii(tiff, find_entry(tiff, *exif_ifd, 0xA433));
    if (const auto iso =
            entry_unsigned(tiff, find_entry(tiff, *exif_ifd, 0x8827))) {
      metadata.iso = *iso;
    }
    if (const auto exposure =
            entry_rational(tiff, find_entry(tiff, *exif_ifd, 0x829A))) {
      metadata.exposure_seconds = *exposure;
    }
    if (const auto aperture =
            entry_rational(tiff, find_entry(tiff, *exif_ifd, 0x829D))) {
      metadata.aperture = *aperture;
    }
    if (const auto focal =
            entry_rational(tiff, find_entry(tiff, *exif_ifd, 0x920A))) {
      metadata.focal_length_mm = *focal;
    }
    if (const auto focal35 =
            entry_unsigned(tiff, find_entry(tiff, *exif_ifd, 0xA405))) {
      metadata.focal_length_35mm = *focal35;
    }
  }

  if (const auto gps_ifd =
          entry_unsigned(tiff, find_entry(tiff, *ifd0, 0x8825));
      gps_ifd && tiff.contains(*gps_ifd, 2)) {
    const auto latitude = gps_coordinate(tiff, *gps_ifd, 0x0002, 0x0001);
    const auto longitude = gps_coordinate(tiff, *gps_ifd, 0x0004, 0x0003);
    if (latitude && longitude && std::isfinite(*latitude) &&
        std::isfinite(*longitude) && std::abs(*latitude) <= 90.0 &&
        std::abs(*longitude) <= 180.0) {
      GpsPosition gps{*latitude, *longitude, std::nullopt};
      if (const auto altitude =
              entry_rational(tiff, find_entry(tiff, *gps_ifd, 0x0006))) {
        const auto below_sea_level =
            entry_unsigned(tiff, find_entry(tiff, *gps_ifd, 0x0005));
        gps.altitude_metres = below_sea_level && *below_sea_level != 0
                                  ? -*altitude
                                  : *altitude;
      }
      metadata.gps = gps;
    }
  }
  return metadata;
}

std::optional<PhotoMetadata> read_jpeg_photo_metadata(
    const std::uint8_t* data, std::size_t size) {
  if (data == nullptr || size < 4 || data[0] != 0xFF || data[1] != 0xD8) {
    return std::nullopt;
  }
  std::size_t cursor = 2;
  while (cursor + 4 <= size) {
    if (data[cursor] != 0xFF) return std::nullopt;
    while (cursor < size && data[cursor] == 0xFF) ++cursor;
    if (cursor >= size) return std::nullopt;
    const std::uint8_t marker = data[cursor++];
    if (marker == 0xD9 || marker == 0xDA) break;
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) continue;
    if (cursor + 2 > size) return std::nullopt;
    const std::size_t segment_size =
        (static_cast<std::size_t>(data[cursor]) << 8) | data[cursor + 1];
    if (segment_size < 2 || segment_size > size - cursor) return std::nullopt;
    const auto* payload = data + cursor + 2;
    const std::size_t payload_size = segment_size - 2;
    if (marker == 0xE1 && payload_size >= 6 &&
        std::memcmp(payload, "Exif\0\0", 6) == 0) {
      return read_photo_metadata(payload, payload_size);
    }
    cursor += segment_size;
  }
  return std::nullopt;
}

std::optional<std::uint16_t> read_exif_orientation(const std::uint8_t* data,
                                                   std::size_t size) {
  // A TIFF header is 8 bytes and IFD0 needs at least a 2-byte entry count.
  if (data == nullptr || size < 10) return std::nullopt;
  bool big_endian = false;
  if (data[0] == 'M' && data[1] == 'M') big_endian = true;
  else if (!(data[0] == 'I' && data[1] == 'I')) return std::nullopt;

  const auto u16 = [&](std::size_t offset) -> std::uint16_t {
    return big_endian ? static_cast<std::uint16_t>((data[offset] << 8) | data[offset + 1])
                      : static_cast<std::uint16_t>(data[offset] |
                                                   (data[offset + 1] << 8));
  };
  const auto u32 = [&](std::size_t offset) -> std::uint32_t {
    const auto a = static_cast<std::uint32_t>(data[offset]);
    const auto b = static_cast<std::uint32_t>(data[offset + 1]);
    const auto c = static_cast<std::uint32_t>(data[offset + 2]);
    const auto d = static_cast<std::uint32_t>(data[offset + 3]);
    return big_endian ? (a << 24) | (b << 16) | (c << 8) | d
                      : (d << 24) | (c << 16) | (b << 8) | a;
  };

  if (u16(2) != 42) return std::nullopt;
  const std::uint64_t ifd0 = u32(4);
  // Every arithmetic step below stays in 64 bits and is compared against the
  // block size, so a hostile offset or entry count cannot walk off the buffer.
  if (ifd0 + 2 > size) return std::nullopt;
  const std::uint32_t entries = u16(static_cast<std::size_t>(ifd0));
  if (ifd0 + 2 + static_cast<std::uint64_t>(entries) * 12 > size) return std::nullopt;
  for (std::uint32_t i = 0; i < entries; ++i) {
    const auto entry = static_cast<std::size_t>(ifd0 + 2 + static_cast<std::uint64_t>(i) * 12);
    if (u16(entry) != 0x0112) continue;
    // SHORT, one value, stored inline in the first two bytes of the value field.
    if (u16(entry + 2) != 3 || u32(entry + 4) != 1) return std::nullopt;
    const std::uint16_t orientation = u16(entry + 8);
    if (orientation < 1 || orientation > 8) return std::nullopt;
    return orientation;
  }
  return std::nullopt;
}

ExifRead read_exif(const std::uint8_t* data, std::size_t size) {
  ExifRead result;
  if (auto metadata = read_photo_metadata(data, size)) {
    result.metadata = std::move(*metadata);
  }
  result.orientation = read_exif_orientation(data, size);
  if (result.orientation) result.metadata.orientation = *result.orientation;
  return result;
}

}  // namespace hyperdr
