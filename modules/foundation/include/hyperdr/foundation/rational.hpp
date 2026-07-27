#pragma once

// The exact rational form that both Exif and ISO 21496-1 gain-map metadata
// store. Keeping the float conversion here means the encoder writes precisely
// the value the renderer will read back when it verifies its own output.

#include "hyperdr/foundation/math.hpp"

#include <cstdint>
#include <stdexcept>

namespace hyperdr {

struct Rational {
  std::int32_t numerator{};
  std::uint32_t denominator{1};
};

inline constexpr std::uint32_t kDefaultRationalDenominator = 100000;

// Clamped so the scaled numerator always fits int32 for the default
// denominator: 21470 * 100000 < 2^31.
[[nodiscard]] inline Rational rational_from_float(
    float value, std::uint32_t denominator = kDefaultRationalDenominator) {
  if (denominator == 0) throw std::invalid_argument("zero rational denominator");
  value = clamp_finite(value, -21470.0F, 21470.0F);
  return {static_cast<std::int32_t>(
              std::lround(value * static_cast<float>(denominator))),
          denominator};
}

[[nodiscard]] inline float rational_value(const Rational& value) {
  if (value.denominator == 0) throw std::invalid_argument("zero rational denominator");
  return static_cast<float>(value.numerator) /
         static_cast<float>(value.denominator);
}

}  // namespace hyperdr
