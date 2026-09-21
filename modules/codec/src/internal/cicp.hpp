#pragma once

// Turning a decoded 8-, 10-, 12- or 16-bit RGB buffer into the pipeline's one
// working space: linear Display P3, 32-bit float, unbounded above 1.
//
// This lived inside the HEIF decoder until AVIF arrived needing the identical
// job done from a different library's enums. The code points are the same
// numbers in both -- libheif's `heif_color_primaries` / `heif_transfer_
// characteristics` and libavif's `avifColorPrimaries` / `avifTransfer
// Characteristics` are each a spelling of ITU-T H.273 -- so the shared form
// takes plain integers and each decoder casts its own enum on the way in.
// Duplicating it instead would have meant two transcriptions of the same
// standard that could disagree about, say, what transfer 18 means.

#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/image/transfer.hpp"

#include <lcms2.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr::codec {

// ITU-T H.273 code points, named here rather than taken from a codec header so
// that nothing in this file depends on which library is calling it.
enum : int {
  kCicpPrimariesReserved = 0,
  kCicpPrimariesBt709 = 1,
  kCicpPrimariesUnspecified = 2,
  kCicpPrimariesBt2020 = 9,
  kCicpPrimariesDisplayP3 = 12,  // SMPTE EG 432-1

  kCicpTransferReserved = 0,
  kCicpTransferBt709 = 1,
  kCicpTransferUnspecified = 2,
  kCicpTransferGamma22 = 4,   // BT.470-6 System M
  kCicpTransferGamma28 = 5,   // BT.470-6 System B/G
  kCicpTransferBt601 = 6,
  kCicpTransferLinear = 8,
  kCicpTransferXvycc = 11,    // IEC 61966-2-4
  kCicpTransferBt1361 = 12,
  kCicpTransferSrgb = 13,     // IEC 61966-2-1
  kCicpTransferBt2020_10 = 14,
  kCicpTransferBt2020_12 = 15,
  kCicpTransferPq = 16,       // BT.2100 / ST 2084
  kCicpTransferHlg = 18,      // BT.2100 / ARIB STD-B67
};

[[nodiscard]] inline int cicp_primaries_for_gamut(ColorGamut gamut) {
  switch (gamut) {
    case ColorGamut::kSrgb: return kCicpPrimariesBt709;
    case ColorGamut::kDisplayP3: return kCicpPrimariesDisplayP3;
    case ColorGamut::kRec2020: return kCicpPrimariesBt2020;
  }
  return kCicpPrimariesBt709;
}

[[nodiscard]] inline bool cicp_primaries_unspecified(int primaries) {
  return primaries == kCicpPrimariesReserved ||
         primaries == kCicpPrimariesUnspecified;
}

// The headroom a transfer function can carry above diffuse white, as a linear
// multiple of it. Only the two BT.2100 curves have any; every SDR curve tops
// out at white by construction, and an ICC-described buffer is SDR unless it
// says otherwise, which none of the profiles in circulation do.
[[nodiscard]] inline float transfer_headroom(int transfer) {
  switch (transfer) {
    case kCicpTransferPq: return 10000.0F / kReferenceWhiteNits;
    case kCicpTransferHlg: return 1000.0F / kReferenceWhiteNits;
    default: return 1.0F;
  }
}

// How a decoded buffer describes its own colour. An embedded ICC profile wins
// when supplied here. The container decoder resolves tag precedence first;
// PNG, for example, must ignore iCCP when cICP is present. ICC can describe
// arbitrary primaries, while HEIF and AVIF usually carry CICP natively.
struct SourceColor {
  std::vector<std::uint8_t> icc;
  int primaries{kCicpPrimariesBt709};
  int transfer{kCicpTransferSrgb};

  SourceColor() = default;
  explicit SourceColor(ColorGamut gamut)
      : primaries(cicp_primaries_for_gamut(gamut)) {}
};

struct ProfileDeleter {
  void operator()(void* p) const { cmsCloseProfile(p); }
};
struct TransformDeleter {
  void operator()(void* p) const { cmsDeleteTransform(p); }
};
using ProfileHandle = std::unique_ptr<void, ProfileDeleter>;
using TransformHandle = std::unique_ptr<void, TransformDeleter>;

// The working space: Display P3 primaries, D65, linear. Every decoder path
// lands here, which is what lets the look, the gain map and the encoders
// assume one colour space without asking where the pixels came from.
inline ProfileHandle linear_display_p3_profile() {
  cmsCIExyY white{0.3127, 0.3290, 1.0};
  cmsCIExyYTRIPLE primaries{
      {0.680, 0.320, 1.0}, {0.265, 0.690, 1.0}, {0.150, 0.060, 1.0}};
  cmsToneCurve* curve = cmsBuildGamma(nullptr, 1.0);
  if (!curve) throw std::runtime_error("cannot build a linear tone curve");
  cmsToneCurve* curves[]{curve, curve, curve};
  ProfileHandle profile(cmsCreateRGBProfile(&white, &primaries, curves));
  cmsFreeToneCurve(curve);
  if (!profile) throw std::runtime_error("cannot build the linear Display P3 profile");
  return profile;
}

inline float decode_transfer(float encoded, int transfer) {
  switch (transfer) {
    case kCicpTransferLinear:
      return encoded;
    // PQ and HLG are decoded by the exact inverses of the functions the
    // encoders use, so a file this project wrote reads back as the image it
    // rendered rather than as a second opinion about BT.2100.
    case kCicpTransferPq:
      return pq_eotf(encoded);
    case kCicpTransferHlg:
      // The HLG OOTF works on a pixel's luminance, so no single channel can
      // be decoded on its own; encoded_to_linear_p3 decodes the whole pixel.
      throw std::logic_error("HLG decodes whole pixels, not single channels");
    case kCicpTransferSrgb:
      return srgb_eotf(encoded);
    // The four SDR broadcast curves are one function, and it is not sRGB.
    case kCicpTransferBt709:
    case kCicpTransferBt601:
    case kCicpTransferBt2020_10:
    case kCicpTransferBt2020_12:
    // xvYCC and BT.1361 are the same curve with an extended range.
    case kCicpTransferXvycc:
    case kCicpTransferBt1361:
      return bt709_inverse_oetf(encoded);
    case kCicpTransferGamma22:
      return std::pow(std::max(0.0F, encoded), 2.2F);
    case kCicpTransferGamma28:
      return std::pow(std::max(0.0F, encoded), 2.8F);
    // 0 and 2 mean "not stated"; 0 is also what a zero-initialised nclx box
    // yields. sRGB is the documented assumption for an 8-bit still image, and
    // saying so here beats a silent default buried in a fallthrough.
    case kCicpTransferReserved:
    case kCicpTransferUnspecified:
      return srgb_eotf(encoded);
    default:
      break;
  }
  throw std::runtime_error("unsupported CICP transfer characteristic " +
                           std::to_string(transfer));
}

// Luminance weights of a signal's primaries, for the HLG OOTF. BT.2100 defines
// HLG on Rec.2020; a file that pairs HLG with other primaries gets theirs.
[[nodiscard]] inline std::array<float, 3> cicp_luminance_weights(int primaries) {
  switch (primaries) {
    case kCicpPrimariesBt2020: return kRec2020Luminance;
    case kCicpPrimariesDisplayP3: return {0.2289746F, 0.6917385F, 0.0792869F};
    default: return {0.2126F, 0.7152F, 0.0722F};
  }
}

inline std::array<float, 3> encoded_to_linear_p3(float r, float g, float b,
                                                 int primaries, int transfer) {
  std::array<float, 3> linear{};
  if (transfer == kCicpTransferHlg) {
    linear = hlg_decode({r, g, b}, cicp_luminance_weights(primaries));
  } else {
    linear = {decode_transfer(r, transfer), decode_transfer(g, transfer),
              decode_transfer(b, transfer)};
  }
  const float R = linear[0];
  const float G = linear[1];
  const float B = linear[2];
  switch (primaries) {
    case kCicpPrimariesDisplayP3:
      return {R, G, B};
    case kCicpPrimariesBt2020:
      return rec2020_to_linear_p3(R, G, B);
    case kCicpPrimariesBt709:
    case kCicpPrimariesUnspecified:
    case kCicpPrimariesReserved:
      return rec709_to_linear_p3(R, G, B);
    default:
      break;
  }
  // Explicit dispatch, not a Rec.709 catch-all: silently treating unknown
  // primaries as Rec.709 is how a wide-gamut capture loses its saturation
  // without anything in the log saying so.
  throw std::runtime_error("unsupported CICP colour primaries " +
                           std::to_string(primaries));
}

// One immutable transform per image, shared by independently converted rows.
// Tabulate finite integer codes exactly (no interpolation). HLG tabulates only
// its inverse OETF; the luminance-dependent OOTF still runs per pixel.
enum class RgbAlpha { None, Straight, Premultiplied };

class RgbRowTransform {
 public:
  RgbRowTransform(const SourceColor& color, int bits, bool narrow_range = false,
                  bool allow_gray = false, RgbAlpha alpha = RgbAlpha::None)
      : primaries_(color.primaries), hlg_(color.transfer == kCicpTransferHlg),
        wide_(bits > 8), alpha_(alpha), transfer_code_(color.transfer) {
    if (bits < 1 || bits > 16 || (narrow_range && bits < 8))
      throw std::runtime_error("decoded image has invalid RGB depth");
    max_code_ = (1U << bits) - 1U;
    if (!color.icc.empty()) {
      const ProfileHandle source(cmsOpenProfileFromMem(color.icc.data(),
          static_cast<cmsUInt32Number>(color.icc.size())));
      if (!source) throw std::runtime_error("embedded ICC profile is unreadable");
      gray_ = allow_gray && cmsGetColorSpace(source.get()) == cmsSigGrayData;
      if (!gray_ && cmsGetColorSpace(source.get()) != cmsSigRgbData)
        throw std::runtime_error("embedded ICC profile is not an RGB profile");
      const auto destination = linear_display_p3_profile();
      const auto format = alpha_ == RgbAlpha::Premultiplied
          ? (gray_ ? TYPE_GRAY_FLT : TYPE_RGB_FLT)
          : gray_ ? (wide_ ? TYPE_GRAY_16 : TYPE_GRAY_8) : (wide_ ? TYPE_RGB_16 : TYPE_RGB_8);
      transform_.reset(cmsCreateTransform(source.get(), format, destination.get(),
          TYPE_RGB_FLT, INTENT_RELATIVE_COLORIMETRIC, 0));
      if (!transform_) throw std::runtime_error("cannot build the ICC colour transform");
    } else {
      (void)encoded_to_linear_p3(0, 0, 0, primaries_, color.transfer);
      const float black = static_cast<float>(narrow_range ? 16U << (bits - 8) : 0);
      const float span = static_cast<float>(narrow_range ? 219U << (bits - 8) : max_code_);
      transfer_.resize(max_code_ + 1);
      for (unsigned code = 0; code <= max_code_; ++code) {
        const float signal = (static_cast<float>(code) - black) / span;
        transfer_[code] = hlg_ ? hlg_inverse_oetf_scene(signal)
            : std::copysign(decode_transfer(std::abs(signal), color.transfer), signal);
      }
    }
  }

  void convert(const std::uint8_t* row, float* target, std::uint32_t width) const {
    convert(row, target, width, true);
  }

  void convert(const std::uint8_t* row, float* target, std::uint32_t width,
               bool composite_alpha) const {
    if (alpha_ == RgbAlpha::None) {
      convert_rgb(row, target, width);
      return;
    }
    if (alpha_ == RgbAlpha::Premultiplied) {
      // Undo association in the encoded domain, without another integer
      // quantization. Alpha itself is linear and always spans the full range.
      const unsigned channels = gray_ ? 1 : 3;
      std::vector<float> packed(static_cast<std::size_t>(width) * channels);
      for (unsigned x = 0; x < width; ++x) {
        const float alpha = static_cast<float>(sample(row, static_cast<std::size_t>(x) * 4 + 3));
        for (unsigned c = 0; c < channels; ++c)
          packed[static_cast<std::size_t>(x) * channels + c] = alpha > 0
              ? std::min(static_cast<float>(sample(row, static_cast<std::size_t>(x) * 4 + c)) / alpha, 1.0F)
              : 0.0F;
      }
      if (transform_) {
        cmsDoTransform(transform_.get(), packed.data(), target, width);
      } else {
        for (unsigned x = 0; x < width; ++x) {
          const auto i = static_cast<std::size_t>(x) * 3;
          const auto linear = encoded_to_linear_p3(packed[i], packed[i + 1], packed[i + 2],
                                                   primaries_, transfer_code_);
          std::copy(linear.begin(), linear.end(), target + i);
        }
      }
    } else {
      const unsigned bytes = wide_ ? 2 : 1;
      std::vector<std::uint8_t> packed(static_cast<std::size_t>(width) * 3 * bytes);
      for (unsigned x = 0; x < width; ++x)
        std::copy_n(row + static_cast<std::size_t>(x) * 4 * bytes, 3 * bytes,
                    packed.data() + static_cast<std::size_t>(x) * 3 * bytes);
      convert_rgb(packed.data(), target, width);
    }
    if (composite_alpha) {
      for (unsigned x = 0; x < width; ++x) {
        const float alpha = static_cast<float>(sample(row, static_cast<std::size_t>(x) * 4 + 3)) / max_code_;
        for (unsigned c = 0; c < 3; ++c) {
          auto& value = target[static_cast<std::size_t>(x) * 3 + c];
          value = alpha == 0 ? 0 : value * alpha;
        }
      }
    }
  }

 private:
  void convert_rgb(const std::uint8_t* row, float* target, std::uint32_t width) const {
    if (transform_) {
      // RGB outputs keep the stream's 10/12-bit codes. LCMS's integer formats
      // instead span all 16 bits. Also pack libpng-expanded gray back to one
      // channel when its ICC profile describes gray.
      if (wide_ && (max_code_ != 65535 || gray_)) {
        const unsigned channels = gray_ ? 1 : 3;
        std::vector<std::uint16_t> packed(static_cast<std::size_t>(width) * channels);
        for (std::size_t i = 0; i < packed.size(); ++i)
          packed[i] = static_cast<std::uint16_t>(
              (sample(row, gray_ ? i * 3 : i) * 65535U + max_code_ / 2U) / max_code_);
        cmsDoTransform(transform_.get(), packed.data(), target, width);
      } else if (gray_) {
        std::vector<std::uint8_t> packed(width);
        for (unsigned x = 0; x < width; ++x) packed[x] = row[x * 3];
        cmsDoTransform(transform_.get(), packed.data(), target, width);
      } else {
        cmsDoTransform(transform_.get(), row, target, width);
      }
      return;  // Keep negative P3 components; rendering owns gamut mapping.
    }
    for (unsigned x = 0; x < width; ++x) {
      const auto index = static_cast<std::size_t>(x) * 3;
      std::array<float, 3> linear{transfer_[sample(row, index)],
          transfer_[sample(row, index + 1)], transfer_[sample(row, index + 2)]};
      if (hlg_) linear = hlg_ootf(linear, cicp_luminance_weights(primaries_));
      const auto p3 = encoded_to_linear_p3(linear[0], linear[1], linear[2],
                                          primaries_, kCicpTransferLinear);
      std::copy(p3.begin(), p3.end(), target + index);
    }
  }

  [[nodiscard]] unsigned sample(const std::uint8_t* row, std::size_t index) const {
    return wide_ ? row[index * 2] | (static_cast<unsigned>(row[index * 2 + 1]) << 8)
                 : row[index];
  }
  int primaries_{};
  bool hlg_{}, wide_{}, gray_{};
  RgbAlpha alpha_{};
  int transfer_code_{};
  unsigned max_code_{};
  TransformHandle transform_;
  std::vector<float> transfer_;
};

// Convert before reducing. Each worker keeps only one full-width linear row;
// no full-resolution float image is materialized for a bounded preview.
// The encoded source is immutable, so rows may be read concurrently. Uniform
// area footprints preserve linear energy, including odd dimensions and signed
// out-of-gamut components. Only downscaling belongs at the decoder boundary.
inline FloatImage interleaved_rgb_to_linear_p3(const std::uint8_t* pixels,
                                               std::uint32_t width,
                                               std::uint32_t height,
                                               std::size_t stride, int bits,
                                               const SourceColor& color,
                                               std::uint32_t out_width = 0,
                                               std::uint32_t out_height = 0,
                                               RgbAlpha alpha = RgbAlpha::None,
                                               bool composite_alpha = true) {
  if (!pixels || !width || !height)
    throw std::runtime_error("decoded image has invalid RGB dimensions");
  if (!out_width) out_width = width;
  if (!out_height) out_height = height;
  if (out_width > width || out_height > height)
    throw std::runtime_error("decoded preview cannot enlarge the source");
  const RgbRowTransform transform(color, bits, false, false, alpha);
  FloatImage linear(out_width, out_height, 3);
  if (out_width == width && out_height == height) {
    parallel_for_rows(height, [&](std::uint32_t y) {
      transform.convert(pixels + static_cast<std::size_t>(y) * stride,
          linear.pixels.data() + static_cast<std::size_t>(y) * width * 3, width, composite_alpha);
    });
    return linear;
  }
  parallel_for_rows(out_height, [&](std::uint32_t oy) {
    std::vector<float> row(static_cast<std::size_t>(width) * 3);
    auto* target = linear.pixels.data() + static_cast<std::size_t>(oy) * out_width * 3;
    const auto top = static_cast<std::uint64_t>(oy) * height;
    const auto bottom = static_cast<std::uint64_t>(oy + 1) * height;
    for (auto sy = top / out_height; sy <= (bottom - 1) / out_height; ++sy) {
      transform.convert(pixels + sy * stride, row.data(), width, composite_alpha);
      const double wy = static_cast<double>(std::min(bottom, (sy + 1) * out_height) -
          std::max(top, sy * out_height)) / height;
      for (std::uint32_t ox = 0; ox < out_width; ++ox) {
        const auto left = static_cast<std::uint64_t>(ox) * width;
        const auto right = static_cast<std::uint64_t>(ox + 1) * width;
        std::array<double, 3> sum{};
        for (auto sx = left / out_width; sx <= (right - 1) / out_width; ++sx) {
          const double wx = static_cast<double>(std::min(right, (sx + 1) * out_width) -
              std::max(left, sx * out_width)) / width;
          for (unsigned c = 0; c < 3; ++c) sum[c] += row[sx * 3 + c] * wx;
        }
        for (unsigned c = 0; c < 3; ++c)
          target[static_cast<std::size_t>(ox) * 3 + c] += static_cast<float>(sum[c] * wy);
      }
    }
  });
  return linear;
}

}  // namespace hyperdr::codec
