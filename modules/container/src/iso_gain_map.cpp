#include "hyperdr/container/iso_gain_map.hpp"

#include <cmath>
#include <cstdint>
#include <span>
#include <stdexcept>
#include <vector>

namespace hyperdr {
namespace {

void append_u16(std::vector<std::uint8_t>& out, std::uint16_t value) {
  out.push_back(static_cast<std::uint8_t>(value >> 8));
  out.push_back(static_cast<std::uint8_t>(value));
}

void append_u32(std::vector<std::uint8_t>& out, std::uint32_t value) {
  out.push_back(static_cast<std::uint8_t>(value >> 24));
  out.push_back(static_cast<std::uint8_t>(value >> 16));
  out.push_back(static_cast<std::uint8_t>(value >> 8));
  out.push_back(static_cast<std::uint8_t>(value));
}

std::uint16_t read_u16(std::span<const std::uint8_t> data, std::size_t& pos) {
  if (pos + 2 > data.size()) throw std::invalid_argument("truncated tmap payload");
  const auto value = static_cast<std::uint16_t>((data[pos] << 8) | data[pos + 1]);
  pos += 2;
  return value;
}

std::uint32_t read_u32(std::span<const std::uint8_t> data, std::size_t& pos) {
  if (pos + 4 > data.size()) throw std::invalid_argument("truncated tmap payload");
  const auto value = (static_cast<std::uint32_t>(data[pos]) << 24) |
                     (static_cast<std::uint32_t>(data[pos + 1]) << 16) |
                     (static_cast<std::uint32_t>(data[pos + 2]) << 8) |
                     static_cast<std::uint32_t>(data[pos + 3]);
  pos += 4;
  return value;
}

void append_rational(std::vector<std::uint8_t>& out, const Rational& value) {
  if (value.denominator == 0) throw std::invalid_argument("zero rational denominator");
  append_u32(out, static_cast<std::uint32_t>(value.numerator));
  append_u32(out, value.denominator);
}

Rational read_rational(std::span<const std::uint8_t> data, std::size_t& pos) {
  const auto numerator = static_cast<std::int32_t>(read_u32(data, pos));
  const auto denominator = read_u32(data, pos);
  if (denominator == 0) throw std::invalid_argument("zero rational denominator");
  return {numerator, denominator};
}

}  // namespace

std::vector<std::uint8_t> serialize_tmap_payload(const GainMapMetadata& metadata) {
  if (metadata.minimum_version != 0 || metadata.writer_version != 0) {
    throw std::invalid_argument("only ISO gain-map v0 metadata can be written");
  }
  if (metadata.backward_direction) {
    throw std::invalid_argument("backward-direction gain maps are not supported");
  }
  std::vector<std::uint8_t> out;
  out.reserve(metadata.common_denominator ? 39 : 62);
  out.push_back(0);  // ToneMapImage version.
  append_u16(out, metadata.minimum_version);
  append_u16(out, metadata.writer_version);
  std::uint8_t flags = metadata.flags;
  if (metadata.use_base_color_space) flags |= 0x40; else flags &= ~0x40U;
  if (metadata.common_denominator) flags |= 0x08; else flags &= ~0x08U;
  if (flags & (0x80U | 0x04U | ~0x48U)) {
    throw std::invalid_argument("unsupported gain-map flags");
  }
  out.push_back(flags);
  if (metadata.common_denominator) {
    const auto denominator = metadata.base_headroom.denominator;
    const auto same = [&](const Rational& value) { return value.denominator == denominator; };
    if (denominator == 0 || !same(metadata.alternate_headroom) ||
        !same(metadata.gain_min) || !same(metadata.gain_max) ||
        !same(metadata.gamma) || !same(metadata.base_offset) ||
        !same(metadata.alternate_offset)) {
      throw std::invalid_argument("common-denominator metadata has mismatched denominators");
    }
    append_u32(out, denominator);
    append_u32(out, static_cast<std::uint32_t>(metadata.base_headroom.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.alternate_headroom.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.gain_min.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.gain_max.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.gamma.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.base_offset.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.alternate_offset.numerator));
  } else {
    append_rational(out, metadata.base_headroom);
    append_rational(out, metadata.alternate_headroom);
    append_rational(out, metadata.gain_min);
    append_rational(out, metadata.gain_max);
    append_rational(out, metadata.gamma);
    append_rational(out, metadata.base_offset);
    append_rational(out, metadata.alternate_offset);
  }
  return out;
}

GainMapMetadata parse_tmap_payload(const std::vector<std::uint8_t>& payload) {
  std::span<const std::uint8_t> data(payload);
  std::size_t pos = 0;
  if (data.size() < 6 || data[pos++] != 0) throw std::invalid_argument("unsupported ToneMapImage version");
  const auto minimum_version = read_u16(data, pos);
  const auto writer_version = read_u16(data, pos);
  if (minimum_version != 0 || writer_version != 0) {
    throw std::invalid_argument("unsupported ISO gain-map version");
  }
  const auto flags = data[pos++];
  if ((flags & 0x80U) != 0) throw std::invalid_argument("multichannel gain maps are not supported");
  if ((flags & 0x04U) != 0) throw std::invalid_argument("backward-direction gain maps are not supported");
  if ((flags & ~0x48U) != 0) throw std::invalid_argument("reserved gain-map flags are set");
  GainMapMetadata metadata;
  metadata.minimum_version = minimum_version;
  metadata.writer_version = writer_version;
  metadata.flags = flags;
  metadata.use_base_color_space = (flags & 0x40U) != 0;
  metadata.common_denominator = (flags & 0x08U) != 0;
  if (metadata.common_denominator) {
    const auto denominator = read_u32(data, pos);
    if (denominator == 0) throw std::invalid_argument("zero common denominator");
    const auto base_n = read_u32(data, pos);
    const auto alternate_n = read_u32(data, pos);
    metadata.base_headroom = {static_cast<std::int32_t>(base_n), denominator};
    metadata.alternate_headroom = {static_cast<std::int32_t>(alternate_n), denominator};
    metadata.gain_min = {static_cast<std::int32_t>(read_u32(data, pos)), denominator};
    metadata.gain_max = {static_cast<std::int32_t>(read_u32(data, pos)), denominator};
    metadata.gamma = {static_cast<std::int32_t>(read_u32(data, pos)), denominator};
    metadata.base_offset = {static_cast<std::int32_t>(read_u32(data, pos)), denominator};
    metadata.alternate_offset = {static_cast<std::int32_t>(read_u32(data, pos)), denominator};
  } else {
    metadata.base_headroom = read_rational(data, pos);
    metadata.alternate_headroom = read_rational(data, pos);
    metadata.gain_min = read_rational(data, pos);
    metadata.gain_max = read_rational(data, pos);
    metadata.gamma = read_rational(data, pos);
    metadata.base_offset = read_rational(data, pos);
    metadata.alternate_offset = read_rational(data, pos);
  }
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alternate_headroom = rational_value(metadata.alternate_headroom);
  const float gain_min = rational_value(metadata.gain_min);
  const float gain_max = rational_value(metadata.gain_max);
  const float gamma = rational_value(metadata.gamma);
  const float base_offset = rational_value(metadata.base_offset);
  const float alternate_offset = rational_value(metadata.alternate_offset);
  if (base_headroom < 0.0F || alternate_headroom < 0.0F) {
    throw std::invalid_argument("negative HDR headroom");
  }
  if (gain_max < gain_min || std::abs(gain_min) > 64.0F || std::abs(gain_max) > 64.0F) {
    throw std::invalid_argument("invalid gain-map range");
  }
  // gain_max and alternate_headroom are not the same quantity and must not be
  // cross-checked here. gain_max is the coding range of the stored map -- the
  // largest per-pixel gain it can express -- while alternate_headroom is the
  // display headroom the whole rendition asks for. They coincide only when the
  // brightest pixel is also the most-gained one. Requiring equality rejected
  // the converter's own output: `verify_heic_decodable` parses the file it just
  // wrote, so a flat bright field (gain_max 2.03 against 2.00 stops of
  // headroom) failed conversion outright, and previously valid files began
  // reporting "structurally invalid". The v2 sidecar path keeps the equality
  // check in external.cpp, where the model constructs both from one number.
  if (!(gamma > 0.0F) || gamma > 64.0F) throw std::invalid_argument("invalid gain-map gamma");
  if (std::abs(base_offset) > 64.0F || std::abs(alternate_offset) > 64.0F) {
    throw std::invalid_argument("invalid gain-map offset");
  }
  // Writer versions newer than this reader may append fields while declaring
  // minimum_version=0. Version-zero payloads must remain exact.
  if (writer_version == 0 && pos != data.size()) {
    throw std::invalid_argument("unexpected trailing ToneMapImage data");
  }
  return metadata;
}

}  // namespace hyperdr
