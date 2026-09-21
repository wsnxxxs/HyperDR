#include "../src/internal/cicp.hpp"

#include <iostream>

namespace {

std::vector<std::uint8_t> linear_rec2020_profile() {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{
      {0.708, 0.292, 1.0}, {0.170, 0.797, 1.0}, {0.131, 0.046, 1.0}};
  auto* curve = cmsBuildGamma(nullptr, 1.0);
  if (!curve) throw std::runtime_error("cannot create test tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  hyperdr::codec::ProfileHandle profile(cmsCreateRGBProfile(&white, &primaries, curves));
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot create test ICC profile");
  cmsUInt32Number size = 0;
  if (!cmsSaveProfileToMem(profile.get(), nullptr, &size))
    throw std::runtime_error("cannot size test ICC profile");
  std::vector<std::uint8_t> bytes(size);
  if (!cmsSaveProfileToMem(profile.get(), bytes.data(), &size))
    throw std::runtime_error("cannot serialize test ICC profile");
  return bytes;
}

void check_depth(int bits, const hyperdr::codec::SourceColor& color) {
  const auto maximum = static_cast<std::uint16_t>((1U << bits) - 1U);
  const auto middle = static_cast<std::uint16_t>(maximum / 2);
  const std::uint16_t pixels[]{maximum, 0, 0, 0, maximum, 0, middle, middle, middle};
  const auto output = hyperdr::codec::interleaved_rgb_to_linear_p3(
      reinterpret_cast<const std::uint8_t*>(pixels), 3, 1, sizeof(pixels), bits, color);
  const float gray = static_cast<float>(middle) / maximum;
  const std::array<std::array<float, 3>, 3> expected{
      hyperdr::rec2020_to_linear_p3(1, 0, 0),
      hyperdr::rec2020_to_linear_p3(0, 1, 0),
      hyperdr::rec2020_to_linear_p3(gray, gray, gray)};
  for (unsigned x = 0; x < 3; ++x) for (unsigned c = 0; c < 3; ++c) {
    const float actual = output.at(x, 0, c);
    // ICC XYZ tags are fixed-point; allow their serialization rounding, not
    // gamut clipping or a 10/12-bit sample interpreted as full 16-bit input.
    if (!std::isfinite(actual) || std::abs(actual - expected[x][c]) > 3.0e-4F)
      throw std::runtime_error("linear Rec.2020 ICC differs from the signed P3 matrix");
  }
  if (!(output.at(0, 0, 1) < -0.05F && output.at(1, 0, 0) < -0.2F))
    throw std::runtime_error("ICC conversion discarded out-of-P3 negative components");
}

void check_odd_reduction(const hyperdr::codec::SourceColor& color) {
  // The last source column is green and the last row blue. With uniform
  // footprints, they cover 3/19 and 2/11 of the bottom-right output pixel.
  // Padding ensures the row stride, rather than width alone, locates samples.
  for (int bits : {8, 10, 12, 16}) {
    const unsigned bytes = bits > 8 ? 2 : 1;
    const std::size_t stride = 19 * 3 * bytes + 10;
    const unsigned maximum = (1U << bits) - 1;
    std::vector<std::uint8_t> pixels(stride * 11);
    for (unsigned y = 0; y < 11; ++y) for (unsigned x = 0; x < 19; ++x)
      for (unsigned c = 0; c < 3; ++c) {
        const unsigned value = ((c == 1 && x == 18) || (c == 2 && y == 10)) ? maximum : 0;
        const auto offset = y * stride + (x * 3 + c) * bytes;
        pixels[offset] = static_cast<std::uint8_t>(value);
        if (bytes == 2) pixels[offset + 1] = static_cast<std::uint8_t>(value >> 8);
      }
    const auto output = hyperdr::codec::interleaved_rgb_to_linear_p3(
        pixels.data(), 19, 11, stride, bits, color, 3, 2);
    for (unsigned y = 0; y < 2; ++y) for (unsigned x = 0; x < 3; ++x) {
      const auto expected = hyperdr::rec2020_to_linear_p3(
          0, x == 2 ? 3.0F / 19 : 0, y == 1 ? 2.0F / 11 : 0);
      for (unsigned c = 0; c < 3; ++c)
        if (!std::isfinite(output.at(x, y, c)) ||
            std::abs(output.at(x, y, c) - expected[c]) > 3e-4F)
          throw std::runtime_error("RGB reduction changed odd-edge area, stride or signed gamut");
    }
  }
}

}  // namespace

int main() {
  try {
    hyperdr::codec::SourceColor color;
    color.icc = linear_rec2020_profile();
    for (int bits : {16, 10, 12}) check_depth(bits, color);
    check_odd_reduction(color);
    color.icc.clear();
    color.primaries = hyperdr::codec::kCicpPrimariesBt2020;
    color.transfer = hyperdr::codec::kCicpTransferLinear;
    check_odd_reduction(color);
    std::cout << "ICC signed gamut and sample normalization passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
