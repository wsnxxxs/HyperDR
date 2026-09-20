#include "hyperdr/codec/dcp_profile.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/hash.hpp"
#include <algorithm>
#include <bit>
#include <cctype>
#include <cmath>
#include <map>
#include <stdexcept>

namespace hyperdr {
namespace {
[[noreturn]] void invalid(const std::string& reason) {
  throw std::runtime_error("DCP profile: " + reason);
}
struct Entry { std::uint16_t type; std::uint32_t count; std::size_t offset; };
class Reader {
 public:
  explicit Reader(const std::filesystem::path& path) : bytes(read_binary_file(path)) {
    bounds(0, 8);
    little = bytes[0] == 'I' && bytes[1] == 'I';
    if (!little && !(bytes[0] == 'M' && bytes[1] == 'M')) invalid("invalid byte order");
    if (u16(2) != 0x4352) invalid("expected standalone camera profile header 0x4352");
    const std::size_t ifd = u32(4);
    const auto count = u16(ifd);
    bounds(ifd + 2, static_cast<std::size_t>(count) * 12 + 4);
    for (std::size_t i = 0; i < count; ++i) {
      const auto at = ifd + 2 + i * 12;
      const auto tag = u16(at), type = u16(at + 2);
      const auto n = u32(at + 4);
      static constexpr unsigned widths[]{0,1,1,2,4,8,1,1,2,4,8,4,8,4};
      if (type == 0 || type >= std::size(widths)) invalid("unsupported TIFF field type");
      const auto length = static_cast<std::uint64_t>(widths[type]) * n;
      const std::size_t offset = length <= 4 ? at + 8 : u32(at + 8);
      if (length > bytes.size()) invalid("field exceeds file size");
      bounds(offset, static_cast<std::size_t>(length));
      if (!entries.emplace(tag, Entry{type, n, offset}).second) invalid("duplicate tag");
    }
    if (u32(ifd + 2 + static_cast<std::size_t>(count) * 12) != 0)
      invalid("multiple profile IFDs are not supported");
  }
  const Entry* find(unsigned tag) const {
    const auto it = entries.find(tag);
    return it == entries.end() ? nullptr : &it->second;
  }
  std::string text(unsigned tag) const {
    const auto* e = find(tag);
    if (!e) return {};
    if (e->type != 2 || !e->count || bytes[e->offset + e->count - 1] != 0)
      invalid("invalid ASCII tag " + std::to_string(tag));
    const auto* start = reinterpret_cast<const char*>(bytes.data() + e->offset);
    return std::string(start, std::find(start, start + e->count, '\0'));
  }
  std::vector<double> numbers(unsigned tag) const {
    const auto* e = find(tag);
    if (!e) return {};
    std::vector<double> out;
    out.reserve(e->count);
    for (std::uint32_t i = 0; i < e->count; ++i) {
      double value = 0;
      const auto at = e->offset;
      switch(e->type) {
        case 3: value = u16(at + 2ULL*i); break;
        case 4: value = u32(at + 4ULL*i); break;
        case 5: case 10: {
          const auto numerator = u32(at + 8ULL*i), denominator = u32(at + 8ULL*i + 4);
          if (denominator == 0) invalid("zero rational denominator");
          value = e->type == 5 ? static_cast<double>(numerator) / denominator
              : static_cast<double>(std::bit_cast<std::int32_t>(numerator)) /
                std::bit_cast<std::int32_t>(denominator);
          break;
        }
        case 11: value = std::bit_cast<float>(u32(at + 4ULL*i)); break;
        case 12: {
          const auto offset = at + 8ULL*i;
          const std::uint64_t a = u32(offset), b = u32(offset + 4);
          value = std::bit_cast<double>(little ? a | (b << 32) : (a << 32) | b);
          break;
        }
        default: invalid("invalid numeric tag " + std::to_string(tag));
      }
      if (!std::isfinite(value)) invalid("non-finite value");
      out.push_back(value);
    }
    return out;
  }
  double scalar(unsigned tag, double fallback = 0) const {
    const auto values = numbers(tag);
    if (!find(tag)) return fallback;
    if (values.size() != 1) invalid("invalid scalar tag " + std::to_string(tag));
    return values[0];
  }
 private:
  void bounds(std::size_t at, std::size_t count) const {
    if (at > bytes.size() || count > bytes.size() - at) invalid("truncated field");
  }
  std::uint16_t u16(std::size_t at) const {
    bounds(at, 2);
    return little ? bytes[at] | (bytes[at+1] << 8) : (bytes[at] << 8) | bytes[at+1];
  }
  std::uint32_t u32(std::size_t at) const {
    bounds(at, 4);
    std::uint32_t value = 0;
    for (unsigned i = 0; i < 4; ++i) value |= std::uint32_t(bytes[at+i]) << (8*(little ? i : 3-i));
    return value;
  }
  std::vector<std::uint8_t> bytes;
  bool little{true};
  std::map<unsigned, Entry> entries;
};
std::optional<Matrix3d> matrix(const Reader& reader, unsigned tag) {
  if (!reader.find(tag)) return std::nullopt;
  const auto values = reader.numbers(tag);
  if (values.size() != 9) invalid("expected a 3x3 matrix");
  Matrix3d out{};
  for (unsigned i = 0; i < 9; ++i) out[i/3][i%3] = values[i];
  return out;
}
DcpHueSatMap table(const Reader& reader, unsigned dims_tag, unsigned data_tag, unsigned encoding_tag) {
  DcpHueSatMap out;
  if (!reader.find(data_tag)) return out;
  const auto dims = reader.numbers(dims_tag);
  if (dims.size() != 3) invalid("missing table dimensions");
  std::uint64_t size = 1;
  for (unsigned i = 0; i < 3; ++i) {
    if (dims[i] < 1 || dims[i] > 65536 || dims[i] != std::floor(dims[i])) invalid("invalid table dimension");
    out.dims[i] = static_cast<std::uint32_t>(dims[i]);
    size *= out.dims[i];
  }
  if (out.dims[1] < 2) invalid("table requires at least two saturation divisions");
  const auto* entry = reader.find(data_tag);
  if (size * 3 != entry->count || entry->type != 11) invalid("table payload size/type does not match dimensions");
  const auto encoding = reader.scalar(encoding_tag);
  if (encoding != 0 && encoding != 1) invalid("unsupported table encoding");
  out.srgb_encoding = encoding == 1;
  const auto values = reader.numbers(data_tag);
  out.values.resize(static_cast<std::size_t>(size));
  for (std::size_t i = 0; i < size; ++i) {
    if (values[i*3+1] < 0 || values[i*3+2] < 0) invalid("negative table scale");
    for (unsigned c = 0; c < 3; ++c) out.values[i][c] = static_cast<float>(values[i*3+c]);
  }
  return out;
}
std::string normalized(std::string_view text) {
  std::string out;
  bool space = false;
  for (const unsigned char c : text) {
    if (std::isspace(c)) { space = !out.empty(); continue; }
    if (space) out.push_back(' ');
    space = false;
    out.push_back(static_cast<char>(std::tolower(c)));
  }
  return out;
}
}  // namespace
DcpProfile read_dcp_profile(const std::filesystem::path& path) {
  Reader reader(path);
  // These tags change the rendering model and must never be silently ignored.
  for (unsigned tag : {52525U,52528U,52529U,52530U,52531U,52532U,52533U,
                       52534U,52535U,52536U,52537U,52544U,52551U}) {
    if (reader.find(tag)) invalid("unsupported rendering tag " + std::to_string(tag));
  }
  DcpProfile out;
  out.name = reader.text(50936);
  out.camera_model = reader.text(50708);
  out.calibration_signature = reader.text(50932);
  out.copyright = reader.text(50942);
  out.sha256 = sha256_file_hex(path);
  for (unsigned i = 0; i < 2; ++i) {
    auto& c = out.color.calibrations[i];
    const auto light = reader.scalar(50778 + i);
    if (light < 0 || light > 254 || light != std::floor(light)) invalid("unsupported calibration illuminant");
    c.illuminant = static_cast<std::uint16_t>(light);
    c.color_matrix = matrix(reader, 50721 + i);
    c.forward_matrix = matrix(reader, 50964 + i);
    out.hue_sat_maps[i] = table(reader, 50937, 50938 + i, 51107);
  }
  if (!out.color.calibrations[0].color_matrix) invalid("ColorMatrix1 is required");
  if (!out.hue_sat_maps[1].values.empty() &&
      (out.hue_sat_maps[0].values.empty() || !out.color.calibrations[1].color_matrix))
    invalid("second HueSatMap requires first map and second calibration");
  out.look_table = table(reader, 50981, 50982, 51108);
  const auto points = reader.numbers(50940);
  if (reader.find(50940) && (points.size() < 4 || points.size()%2)) invalid("invalid tone curve size");
  for (std::size_t i = 0; i < points.size(); i += 2) {
    if (points[i] < 0 || points[i] > 1 || points[i+1] < 0 || points[i+1] > 1 ||
        (i && points[i] <= points[i-2])) invalid("invalid tone curve points");
    out.tone_curve.push_back({points[i], points[i+1]});
  }
  const auto offset = reader.scalar(51109);
  if (std::abs(offset) > 100) invalid("invalid baseline exposure offset");
  out.baseline_exposure_offset = static_cast<float>(offset);
  const auto black = reader.scalar(51110);
  if (black != 0 && black != 1) invalid("unsupported default black rendering");
  out.default_black_render_none = black == 1;
  if (!dng_camera_color_transform(out.color, {1,1,1})) invalid("invalid camera matrices");
  return out;
}
bool dcp_matches_camera(const DcpProfile& profile, std::string_view make, std::string_view model) {
  const auto wanted = normalized(profile.camera_model);
  if (wanted.empty()) return true;
  const auto camera = normalized(model);
  const auto maker = normalized(make);
  return wanted == camera || (!maker.empty() && wanted == maker + " " + camera);
}
}  // namespace hyperdr
