#pragma once

// ISO base media file format primitives: reading a box header, walking a box's
// children, and writing one back out.
//
// Internal to the container module. The public surface is inspection and the
// tone-mapped-item rewrite; nothing outside needs to know how a 64-bit largesize
// header is encoded.

#include <cstdint>
#include <limits>
#include <stdexcept>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace hyperdr::container {

using Bytes = std::vector<std::uint8_t>;

struct Box {
  std::string type;
  std::size_t offset{};
  std::size_t size{};
  std::size_t header{8};
};

inline std::uint16_t be16(std::span<const std::uint8_t> b, std::size_t p) {
  if (p + 2 > b.size()) throw std::runtime_error("truncated uint16");
  return static_cast<std::uint16_t>((b[p] << 8) | b[p + 1]);
}
inline std::uint32_t be32(std::span<const std::uint8_t> b, std::size_t p) {
  if (p + 4 > b.size()) throw std::runtime_error("truncated uint32");
  return (static_cast<std::uint32_t>(b[p]) << 24) |
         (static_cast<std::uint32_t>(b[p + 1]) << 16) |
         (static_cast<std::uint32_t>(b[p + 2]) << 8) | b[p + 3];
}
inline std::uint64_t be64(std::span<const std::uint8_t> b, std::size_t p) {
  return (static_cast<std::uint64_t>(be32(b, p)) << 32) | be32(b, p + 4);
}
inline void put16(Bytes& b, std::uint16_t v) {
  b.push_back(static_cast<std::uint8_t>(v >> 8)); b.push_back(static_cast<std::uint8_t>(v));
}
inline void put32(Bytes& b, std::uint32_t v) {
  b.push_back(static_cast<std::uint8_t>(v >> 24)); b.push_back(static_cast<std::uint8_t>(v >> 16));
  b.push_back(static_cast<std::uint8_t>(v >> 8)); b.push_back(static_cast<std::uint8_t>(v));
}
inline void put64(Bytes& b, std::uint64_t v) { put32(b, static_cast<std::uint32_t>(v >> 32)); put32(b, static_cast<std::uint32_t>(v)); }
inline void set32(Bytes& b, std::size_t p, std::uint32_t v) {
  if (p + 4 > b.size()) throw std::runtime_error("set32 out of range");
  for (unsigned i = 0; i < 4; ++i) b[p + i] = static_cast<std::uint8_t>(v >> ((3 - i) * 8));
}

inline std::uint64_t read_n(std::span<const std::uint8_t> b, std::size_t& p, unsigned n) {
  if (n > 8 || p + n > b.size()) throw std::runtime_error("truncated variable integer");
  std::uint64_t v = 0;
  for (unsigned i = 0; i < n; ++i) v = (v << 8) | b[p++];
  return v;
}

inline Box read_box(std::span<const std::uint8_t> bytes, std::size_t offset, std::size_t end) {
  if (offset + 8 > end || end > bytes.size()) throw std::runtime_error("truncated BMFF box header");
  std::uint64_t size = be32(bytes, offset);
  std::size_t header = 8;
  if (size == 1) { size = be64(bytes, offset + 8); header = 16; }
  else if (size == 0) size = end - offset;
  if (size < header || size > end - offset) throw std::runtime_error("invalid BMFF box size");
  return {std::string(reinterpret_cast<const char*>(bytes.data() + offset + 4), 4), offset,
          static_cast<std::size_t>(size), header};
}

inline std::vector<Box> children(std::span<const std::uint8_t> bytes, std::size_t begin, std::size_t end) {
  std::vector<Box> out;
  for (auto p = begin; p < end;) {
    const auto box = read_box(bytes, p, end);
    out.push_back(box);
    p += box.size;
  }
  return out;
}

inline Bytes slice(std::span<const std::uint8_t> bytes, const Box& box) {
  return Bytes(bytes.begin() + static_cast<std::ptrdiff_t>(box.offset),
               bytes.begin() + static_cast<std::ptrdiff_t>(box.offset + box.size));
}

inline Bytes make_box(std::string_view type, std::span<const std::uint8_t> payload) {
  if (type.size() != 4 || payload.size() > std::numeric_limits<std::uint32_t>::max() - 8)
    throw std::invalid_argument("invalid box");
  Bytes out;
  put32(out, static_cast<std::uint32_t>(payload.size() + 8));
  out.insert(out.end(), type.begin(), type.end());
  out.insert(out.end(), payload.begin(), payload.end());
  return out;
}

inline std::uint32_t fullbox_version(std::span<const std::uint8_t> box) {
  if (box.size() < 12) throw std::runtime_error("truncated full box");
  return box[8];
}

}  // namespace hyperdr::container
