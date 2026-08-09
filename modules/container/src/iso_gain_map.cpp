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

GainMapChannelMetadata flat_channel(const GainMapMetadata& metadata) {
  return {metadata.gain_min, metadata.gain_max, metadata.gamma,
          metadata.base_offset, metadata.alternate_offset};
}

void assign_flat_channel(GainMapMetadata& metadata,
                         const GainMapChannelMetadata& channel) {
  metadata.gain_min = channel.gain_min;
  metadata.gain_max = channel.gain_max;
  metadata.gamma = channel.gamma;
  metadata.base_offset = channel.base_offset;
  metadata.alternate_offset = channel.alternate_offset;
}

void append_channel(std::vector<std::uint8_t>& out,
                    const GainMapChannelMetadata& channel) {
  append_rational(out, channel.gain_min);
  append_rational(out, channel.gain_max);
  append_rational(out, channel.gamma);
  append_rational(out, channel.base_offset);
  append_rational(out, channel.alternate_offset);
}

GainMapChannelMetadata read_channel(std::span<const std::uint8_t> data,
                                    std::size_t& pos) {
  return {read_rational(data, pos), read_rational(data, pos),
          read_rational(data, pos), read_rational(data, pos),
          read_rational(data, pos)};
}

}  // namespace

std::size_t gain_map_channel_count(const GainMapMetadata& metadata) {
  const bool multichannel = (metadata.flags & 0x80U) != 0;
  if (multichannel) {
    if (metadata.channels.size() != 3) {
      throw std::invalid_argument(
          "multichannel gain-map metadata must contain exactly three channels");
    }
    return 3;
  }
  if (!metadata.channels.empty()) {
    throw std::invalid_argument(
        "single-channel gain-map metadata contains a channel array");
  }
  return 1;
}

GainMapChannelMetadata gain_map_channel(const GainMapMetadata& metadata,
                                        std::size_t index) {
  const auto count = gain_map_channel_count(metadata);
  if (index >= count) {
    throw std::out_of_range("gain-map metadata channel is out of range");
  }
  return count == 1 ? flat_channel(metadata) : metadata.channels[index];
}

void validate_gain_map_metadata(const GainMapMetadata& metadata,
                                GainMapWriterProfile profile) {
  if (metadata.minimum_version != 0 || metadata.writer_version != 0) {
    throw std::invalid_argument("unsupported ISO gain-map version");
  }
  if (metadata.backward_direction || (metadata.flags & 0x04U) != 0) {
    throw std::invalid_argument("backward-direction gain maps are not supported");
  }
  if ((metadata.flags & ~0xC8U) != 0) {
    throw std::invalid_argument("reserved gain-map flags are set");
  }
  // The public struct predates the profile validator: these two booleans are
  // canonical for programmatically constructed metadata and serialization
  // rewrites their flag bits. Parsed records always have the fields in sync.

  const auto count = gain_map_channel_count(metadata);
  const float base_headroom = rational_value(metadata.base_headroom);
  const float alternate_headroom = rational_value(metadata.alternate_headroom);
  if (!std::isfinite(base_headroom) || !std::isfinite(alternate_headroom) ||
      base_headroom < 0.0F || alternate_headroom < 0.0F) {
    throw std::invalid_argument("invalid HDR headroom");
  }

  for (std::size_t index = 0; index < count; ++index) {
    const auto channel = gain_map_channel(metadata, index);
    const float gain_min = rational_value(channel.gain_min);
    const float gain_max = rational_value(channel.gain_max);
    const float gamma = rational_value(channel.gamma);
    const float base_offset = rational_value(channel.base_offset);
    const float alternate_offset = rational_value(channel.alternate_offset);
    if (!std::isfinite(gain_min) || !std::isfinite(gain_max) ||
        !std::isfinite(gamma) || !std::isfinite(base_offset) ||
        !std::isfinite(alternate_offset) || gain_max < gain_min ||
        std::abs(gain_min) > 64.0F || std::abs(gain_max) > 64.0F ||
        !(gamma > 0.0F) || gamma > 64.0F ||
        std::abs(base_offset) > 64.0F ||
        std::abs(alternate_offset) > 64.0F) {
      throw std::invalid_argument("invalid gain-map channel metadata");
    }
    if (profile == GainMapWriterProfile::apple_strict &&
        std::abs(gain_max - alternate_headroom) > 1.0e-6F) {
      throw std::invalid_argument(
          "apple_strict gain_max conflicts with alternate_headroom");
    }
  }
  if (profile == GainMapWriterProfile::apple_strict && count != 1) {
    throw std::invalid_argument(
        "apple_strict does not accept multichannel gain maps");
  }

  if (metadata.common_denominator) {
    const auto denominator = metadata.base_headroom.denominator;
    if (denominator == 0 ||
        metadata.alternate_headroom.denominator != denominator) {
      throw std::invalid_argument(
          "common-denominator metadata has mismatched denominators");
    }
    for (std::size_t index = 0; index < count; ++index) {
      const auto channel = gain_map_channel(metadata, index);
      for (const Rational* value :
           {&channel.gain_min, &channel.gain_max, &channel.gamma,
            &channel.base_offset, &channel.alternate_offset}) {
        if (value->denominator != denominator) {
          throw std::invalid_argument(
              "common-denominator metadata has mismatched denominators");
        }
      }
    }
  }
}

std::vector<std::uint8_t> serialize_tmap_payload(const GainMapMetadata& metadata) {
  if (metadata.minimum_version != 0 || metadata.writer_version != 0) {
    throw std::invalid_argument("only ISO gain-map v0 metadata can be written");
  }
  validate_gain_map_metadata(metadata);
  const auto channel_count = gain_map_channel_count(metadata);
  std::vector<std::uint8_t> out;
  out.reserve(metadata.common_denominator ? 18 + 20 * channel_count
                                          : 22 + 40 * channel_count);
  out.push_back(0);  // ToneMapImage version.
  append_u16(out, metadata.minimum_version);
  append_u16(out, metadata.writer_version);
  std::uint8_t flags = metadata.flags;
  if (metadata.use_base_color_space) flags |= 0x40; else flags &= ~0x40U;
  if (metadata.common_denominator) flags |= 0x08; else flags &= ~0x08U;
  if (flags & (0x04U | ~0xC8U)) {
    throw std::invalid_argument("unsupported gain-map flags");
  }
  out.push_back(flags);
  if (metadata.common_denominator) {
    const auto denominator = metadata.base_headroom.denominator;
    append_u32(out, denominator);
    append_u32(out, static_cast<std::uint32_t>(metadata.base_headroom.numerator));
    append_u32(out, static_cast<std::uint32_t>(metadata.alternate_headroom.numerator));
    for (std::size_t index = 0; index < channel_count; ++index) {
      const auto channel = gain_map_channel(metadata, index);
      append_u32(out, static_cast<std::uint32_t>(channel.gain_min.numerator));
      append_u32(out, static_cast<std::uint32_t>(channel.gain_max.numerator));
      append_u32(out, static_cast<std::uint32_t>(channel.gamma.numerator));
      append_u32(out, static_cast<std::uint32_t>(channel.base_offset.numerator));
      append_u32(out,
                 static_cast<std::uint32_t>(channel.alternate_offset.numerator));
    }
  } else {
    append_rational(out, metadata.base_headroom);
    append_rational(out, metadata.alternate_headroom);
    for (std::size_t index = 0; index < channel_count; ++index) {
      append_channel(out, gain_map_channel(metadata, index));
    }
  }
  return out;
}

GainMapMetadata parse_tmap_payload(const std::vector<std::uint8_t>& payload,
                                  GainMapWriterProfile profile) {
  std::span<const std::uint8_t> data(payload);
  std::size_t pos = 0;
  if (data.size() < 6 || data[pos++] != 0) throw std::invalid_argument("unsupported ToneMapImage version");
  const auto minimum_version = read_u16(data, pos);
  const auto writer_version = read_u16(data, pos);
  if (minimum_version != 0 || writer_version != 0) {
    throw std::invalid_argument("unsupported ISO gain-map version");
  }
  const auto flags = data[pos++];
  if ((flags & 0x04U) != 0) throw std::invalid_argument("backward-direction gain maps are not supported");
  if ((flags & ~0xC8U) != 0) throw std::invalid_argument("reserved gain-map flags are set");
  GainMapMetadata metadata;
  metadata.minimum_version = minimum_version;
  metadata.writer_version = writer_version;
  metadata.flags = flags;
  metadata.use_base_color_space = (flags & 0x40U) != 0;
  metadata.common_denominator = (flags & 0x08U) != 0;
  const std::size_t channel_count = (flags & 0x80U) != 0 ? 3 : 1;
  if (metadata.common_denominator) {
    const auto denominator = read_u32(data, pos);
    if (denominator == 0) throw std::invalid_argument("zero common denominator");
    const auto base_n = read_u32(data, pos);
    const auto alternate_n = read_u32(data, pos);
    metadata.base_headroom = {static_cast<std::int32_t>(base_n), denominator};
    metadata.alternate_headroom = {static_cast<std::int32_t>(alternate_n), denominator};
    for (std::size_t index = 0; index < channel_count; ++index) {
      GainMapChannelMetadata channel{
          {static_cast<std::int32_t>(read_u32(data, pos)), denominator},
          {static_cast<std::int32_t>(read_u32(data, pos)), denominator},
          {static_cast<std::int32_t>(read_u32(data, pos)), denominator},
          {static_cast<std::int32_t>(read_u32(data, pos)), denominator},
          {static_cast<std::int32_t>(read_u32(data, pos)), denominator}};
      if (channel_count == 1) assign_flat_channel(metadata, channel);
      else metadata.channels.push_back(channel);
    }
  } else {
    metadata.base_headroom = read_rational(data, pos);
    metadata.alternate_headroom = read_rational(data, pos);
    for (std::size_t index = 0; index < channel_count; ++index) {
      const auto channel = read_channel(data, pos);
      if (channel_count == 1) assign_flat_channel(metadata, channel);
      else metadata.channels.push_back(channel);
    }
  }
  // Writer versions newer than this reader may append fields while declaring
  // minimum_version=0. Version-zero payloads must remain exact.
  if (writer_version == 0 && pos != data.size()) {
    throw std::invalid_argument("unexpected trailing ToneMapImage data");
  }
  validate_gain_map_metadata(metadata, profile);
  return metadata;
}

}  // namespace hyperdr
