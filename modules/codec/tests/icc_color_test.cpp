#include "../src/internal/cicp.hpp"
#include "../src/internal/heif_color.hpp"
#include "../src/internal/icc_profiles.hpp"

#include <iostream>
#include <cstring>

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

void check_float_heif_colour() {
  using namespace hyperdr;
  using namespace hyperdr::codec;
  SourceColor color;
  color.icc=display_p3_profile();
  FloatRgbRowTransform icc(color);
  const float encoded[]{-.125F,1.25F,.5F};
  float output[3];
  icc.convert(encoded,output,1);
  const float expected[]{-.125F/12.92F,std::pow((1.25F+.055F)/1.055F,2.4F),srgb_eotf(.5F)};
  for (unsigned c=0;c<3;++c)
    if (std::abs(output[c]-expected[c])>3e-4F)
      throw std::runtime_error("HEIF float ICC clipped/quantized an encoded excursion");
  std::vector<float> parallel(128*3),serial(128*3);
  for(unsigned y=0;y<128;++y) icc.convert(encoded,serial.data()+y*3,1);
  parallel_for_rows(128,[&](unsigned y){icc.convert(encoded,parallel.data()+y*3,1);});
  if(std::memcmp(parallel.data(),serial.data(),parallel.size()*sizeof(float)))
    throw std::runtime_error("float ICC serial/parallel bytes differ");
  color.icc.clear();
  for(int primaries:{1,9,12}) for(int transfer:{1,8,13,16,18}) {
    color.primaries=primaries;color.transfer=transfer;
    FloatRgbRowTransform transform(color);
    transform.convert(encoded,output,1);
    std::array<float,3> linear;
    for(unsigned c=0;c<3;++c) linear[c]=transfer==18 ? hlg_inverse_oetf_scene(encoded[c])
        : std::copysign(decode_transfer(transfer==16 && encoded[c]>1 ? 1.F : std::abs(encoded[c]),transfer),encoded[c]);
    if(transfer==18)linear=hlg_ootf(linear,cicp_luminance_weights(primaries));
    const auto expected=encoded_to_linear_p3(linear[0],linear[1],linear[2],primaries,8);
    for(unsigned c=0;c<3;++c)
      if(std::abs(output[c]-expected[c])>1e-3F+std::abs(expected[c])*3e-5F)
        throw std::runtime_error("HEIF float CICP lost extended encoded RGB");
  }
  // PQ has no meaning above code 1 and a pole near 1.995, which full-range
  // 10-bit YCbCr reaches (Y=1023, Cb=1023 gives B' ~ 1.94). Positive codes stop
  // at the top of the curve; the negative side keeps its excursion.
  color.primaries=9;color.transfer=16;
  FloatRgbRowTransform pq(color);
  for(float code:{1.F,1.0947F,1.2F,1.737F,1.94F,2.168F,5.F}) {
    const float in[]{code,code,code};
    float out[3];
    pq.convert(in,out,1);
    for(float value:out)
      if(!std::isfinite(value)||value<0||value>50.F)
        throw std::runtime_error("PQ code above 1 left the 10000 nit range");
    if(std::abs(out[0]-out[1])>1e-4F*out[0]||std::abs(out[1]-out[2])>1e-4F*out[1])
      throw std::runtime_error("PQ codes above 1 clamp differently per channel");
  }
  const float small[]{-.0625F,-.0625F,-.0625F},large[]{-.5F,-.5F,-.5F};
  float small_out[3],large_out[3];
  pq.convert(small,small_out,1);
  pq.convert(large,large_out,1);
  if(!(small_out[0]<0&&large_out[0]<small_out[0]))
    throw std::runtime_error("PQ negative excursion was clipped");
}

int main() {
  try {
    check_float_heif_colour();
    hyperdr::codec::SourceColor color;
    color.icc = linear_rec2020_profile();
    for (int bits : {16, 10, 12}) check_depth(bits, color);
    check_odd_reduction(color);
    // The float ICC path must unassociate before conversion and retain signed
    // out-of-P3 values when compositing. Include a sub-16-bit input.
    for (int bits : {8, 10, 16}) {
      const unsigned maximum = (1U << bits) - 1, alpha = maximum / 2;
      std::vector<std::uint8_t> rgba;
      for (unsigned code : {alpha, 0U, 0U, alpha}) {
        rgba.push_back(static_cast<std::uint8_t>(code));
        if (bits > 8) rgba.push_back(static_cast<std::uint8_t>(code >> 8));
      }
      const auto image = hyperdr::codec::interleaved_rgb_to_linear_p3(
          rgba.data(), 1, 1, rgba.size(), bits, color, 0, 0,
          hyperdr::codec::RgbAlpha::Premultiplied);
      const auto expected = hyperdr::rec2020_to_linear_p3(static_cast<float>(alpha) / maximum, 0, 0);
      for (unsigned c = 0; c < 3; ++c)
        if (!std::isfinite(image.pixels[c]) || std::abs(image.pixels[c] - expected[c]) > 3e-4F)
          throw std::runtime_error("premultiplied ICC alpha changed signed linear colour");
    }
    color.icc.clear();
    color.primaries = hyperdr::codec::kCicpPrimariesBt2020;
    color.transfer = hyperdr::codec::kCicpTransferLinear;
    check_odd_reduction(color);
    // Alpha is a linear weight even for PQ/HLG. Premultiplied *encoded*
    // white has RGB=alpha, so unassociation must precede transfer decoding.
    for (int bits : {8, 10, 12, 16}) {
      const unsigned maximum = (1U << bits) - 1, middle = maximum / 2;
      for (int transfer : {hyperdr::codec::kCicpTransferSrgb, hyperdr::codec::kCicpTransferPq,
                           hyperdr::codec::kCicpTransferHlg}) {
        color.transfer = transfer;
        color.primaries = hyperdr::codec::kCicpPrimariesDisplayP3;
        for (auto alpha : {hyperdr::codec::RgbAlpha::Straight, hyperdr::codec::RgbAlpha::Premultiplied}) {
          std::vector<std::uint8_t> rgba;
          const auto put = [&](unsigned v) {
            rgba.push_back(static_cast<std::uint8_t>(v));
            if (bits > 8) rgba.push_back(static_cast<std::uint8_t>(v >> 8));
          };
          for (unsigned a : {0U, middle, maximum}) {
            const unsigned value = alpha == hyperdr::codec::RgbAlpha::Straight ? maximum : a;
            put(value); put(value); put(value); put(a);
          }
          const auto image = hyperdr::codec::interleaved_rgb_to_linear_p3(
              rgba.data(), 3, 1, rgba.size(), bits, color, 1, 1, alpha);
          const float expected = hyperdr::codec::transfer_headroom(transfer) *
              (1 + static_cast<float>(middle) / maximum) / 3;
          for (float value : image.pixels)
            if (!std::isfinite(value) || std::abs(value - expected) > 2e-4F)
              throw std::runtime_error("HDR alpha association or linear reduction is incorrect");
        }
      }
    }
    std::cout << "ICC signed gamut and sample normalization passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
