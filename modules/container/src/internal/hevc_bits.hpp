#pragma once
#include <cstdint>
#include <span>
#include <stdexcept>
#include <vector>

namespace hyperdr::container {
inline unsigned nal_type(std::span<const std::uint8_t> nal) {
  if (nal.size() < 3 || (nal[0] & 0x80) || !(nal[1] & 7))
    throw std::invalid_argument("invalid HEVC NAL header");
  return (nal[0] >> 1) & 63;
}
inline std::vector<std::uint8_t> rbsp(std::span<const std::uint8_t> nal) {
  (void)nal_type(nal);
  std::vector<std::uint8_t> bytes;
  unsigned zeroes = 0;
  for (std::size_t i = 2; i < nal.size(); ++i) {
    const auto value = nal[i];
    if (zeroes == 2 && value == 3) {
      if (i + 1 == nal.size() || nal[i + 1] > 3)
        throw std::invalid_argument("invalid HEVC emulation prevention");
      zeroes = 0;
      continue;
    }
    if (zeroes == 2 && value <= 2) throw std::invalid_argument("missing HEVC emulation prevention");
    bytes.push_back(value);
    zeroes = value == 0 ? zeroes + 1 : 0;
    if (zeroes > 2) zeroes = 2;
  }
  return bytes;
}
class HevcBits {
 public:
  explicit HevcBits(std::span<const std::uint8_t> bytes) : bytes_(bytes) {}
  std::uint32_t take(unsigned count) {
    if (count > 32 || count > bytes_.size() * 8 - position_)
      throw std::invalid_argument("truncated HEVC parameter set");
    std::uint32_t value = 0;
    while (count--) {
      value = (value << 1) | ((bytes_[position_ / 8] >> (7 - position_ % 8)) & 1);
      ++position_;
    }
    return value;
  }
  void skip(unsigned count) { while (count > 32) { (void)take(32); count -= 32; } (void)take(count); }
  std::uint32_t ue() {
    unsigned zeroes = 0;
    while (!take(1)) if (++zeroes > 31) throw std::invalid_argument("HEVC Exp-Golomb overflow");
    return ((std::uint32_t{1} << zeroes) - 1) + take(zeroes);
  }
  void trailing() {
    if (take(1) != 1) throw std::invalid_argument("missing HEVC rbsp stop bit");
    while (position_ % 8) if (take(1)) throw std::invalid_argument("invalid HEVC rbsp padding");
    if (position_ != bytes_.size()*8) throw std::invalid_argument("unexpected HEVC rbsp trailing bytes");
  }
 private:
  std::span<const std::uint8_t> bytes_;
  std::size_t position_{};
};
} // namespace hyperdr::container
