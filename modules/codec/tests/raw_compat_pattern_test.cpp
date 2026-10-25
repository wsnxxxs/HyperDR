#include "../src/internal/raw_compat_internal.hpp"

#include <array>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main() {
  auto raw = std::make_unique<LibRaw>();
  raw->imgdata.sizes.raw_width = 8;
  raw->imgdata.sizes.raw_height = 8;
  std::memcpy(raw->imgdata.idata.cdesc, "RGBG", 5);

  // GRBG: G R / B G. LibRaw's COLOR(row, col) must not be transposed while
  // producing the row-major DNG CFAPattern.
  constexpr std::array<std::array<std::uint8_t, 2>, 2> channels{{{1, 0}, {2, 1}}};
  std::uint32_t filters = 0;
  for (unsigned row = 0; row < 8; ++row) {
    for (unsigned col = 0; col < 2; ++col) {
      const unsigned shift = (((row << 1U & 14U) | (col & 1U)) << 1U);
      filters |= std::uint32_t(channels[row & 1U][col]) << shift;
    }
  }
  raw->imgdata.idata.filters = filters;

  std::array<std::uint8_t, 4> pattern{};
  require(hyperdr::raw_compat_internal::bayer_pattern(*raw, &pattern),
          "GRBG was not recognized as a Bayer pattern");
  constexpr std::array<std::uint8_t, 4> expected{1, 0, 2, 1};
  require(pattern == expected, "GRBG was written with transposed RGB positions");
  return 0;
}
