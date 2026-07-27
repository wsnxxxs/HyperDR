#include "hyperdr/image/transfer.hpp"

#include <array>
#include <cmath>

namespace hyperdr {
namespace {

// 65537 entries covers [0, 1] inclusive at 16-bit resolution, which is finer
// than any depth this project encodes, so interpolation error stays well below
// one code value.
constexpr std::size_t kTransferLutSize = 65536;

template <std::size_t N>
float sample_lut(const std::array<float, N>& lut, float value) {
  const float position = value * static_cast<float>(N - 1);
  const auto index = static_cast<std::size_t>(position);
  if (index + 1 >= N) return lut[N - 1];
  return std::lerp(lut[index], lut[index + 1], position - static_cast<float>(index));
}

const std::array<float, kTransferLutSize + 1>& srgb_oetf_lut() {
  static const auto lut = [] {
    std::array<float, kTransferLutSize + 1> values{};
    for (std::size_t i = 0; i < values.size(); ++i) {
      const float linear = static_cast<float>(i) / static_cast<float>(kTransferLutSize);
      values[i] = linear <= 0.0031308F
                      ? 12.92F * linear
                      : 1.055F * std::pow(linear, 1.0F / 2.4F) - 0.055F;
    }
    return values;
  }();
  return lut;
}

const std::array<float, kTransferLutSize + 1>& srgb_eotf_lut() {
  static const auto lut = [] {
    std::array<float, kTransferLutSize + 1> values{};
    for (std::size_t i = 0; i < values.size(); ++i) {
      const float encoded = static_cast<float>(i) / static_cast<float>(kTransferLutSize);
      values[i] = encoded <= 0.04045F
                      ? encoded / 12.92F
                      : std::pow((encoded + 0.055F) / 1.055F, 2.4F);
    }
    return values;
  }();
  return lut;
}

}  // namespace

float srgb_oetf(float linear) {
  linear = std::max(0.0F, linear);
  if (linear <= 0.0031308F) return 12.92F * linear;
  if (linear <= 1.0F) return sample_lut(srgb_oetf_lut(), linear);
  return 1.055F * std::pow(linear, 1.0F / 2.4F) - 0.055F;
}

float srgb_eotf(float encoded) {
  encoded = std::max(0.0F, encoded);
  if (encoded <= 0.04045F) return encoded / 12.92F;
  if (encoded <= 1.0F) return sample_lut(srgb_eotf_lut(), encoded);
  return std::pow((encoded + 0.055F) / 1.055F, 2.4F);
}

}  // namespace hyperdr
