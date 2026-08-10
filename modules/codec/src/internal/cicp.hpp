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
// when present: it is the only description that can carry an arbitrary set of
// primaries, and JPEG and PNG in the wild use it for exactly that. The CICP
// pair is the fallback, and is what HEIF and AVIF carry natively.
struct SourceColor {
  std::vector<std::uint8_t> icc;
  int primaries{kCicpPrimariesBt709};
  int transfer{kCicpTransferSrgb};
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
      return hlg_inverse_oetf(encoded);
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

inline std::array<float, 3> encoded_to_linear_p3(float r, float g, float b,
                                                 int primaries, int transfer) {
  const float R = decode_transfer(r, transfer);
  const float G = decode_transfer(g, transfer);
  const float B = decode_transfer(b, transfer);
  switch (primaries) {
    case kCicpPrimariesDisplayP3:
      return {std::max(0.0F, R), std::max(0.0F, G), std::max(0.0F, B)};
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

// Converts an interleaved 8- or 16-bit RGB buffer through an embedded ICC
// profile into linear Display P3. Little CMS applies the profile's transfer
// curves and primaries in one step, which is the whole point: a Display P3
// JPEG's pure red must land near (1, 0, 0), not at the (0.82, 0.03, 0.02) that
// decoding it as Rec.709 produces.
inline void convert_rows_with_icc(const std::uint8_t* pixels, std::uint32_t width,
                                  std::uint32_t height, std::size_t stride, int bits,
                                  const std::vector<std::uint8_t>& icc,
                                  FloatImage& out) {
  ProfileHandle source(
      cmsOpenProfileFromMem(icc.data(), static_cast<cmsUInt32Number>(icc.size())));
  if (!source) throw std::runtime_error("embedded ICC profile is unreadable");
  if (cmsGetColorSpace(source.get()) != cmsSigRgbData) {
    throw std::runtime_error("embedded ICC profile is not an RGB profile");
  }
  const ProfileHandle destination = linear_display_p3_profile();
  const bool wide = bits > 8;
  const TransformHandle transform(cmsCreateTransform(
      source.get(), wide ? TYPE_RGB_16 : TYPE_RGB_8, destination.get(),
      TYPE_RGB_FLT, INTENT_RELATIVE_COLORIMETRIC, 0));
  if (!transform) throw std::runtime_error("cannot build the ICC colour transform");

  // TYPE_RGB_16 means samples that fill all sixteen bits, and HEIF and AVIF do
  // not deliver those: libheif's RRGGBB_LE and libavif's RGB buffers keep the
  // stream's own depth, so a 10-bit sample tops out at 1023. Feeding those
  // straight to Little CMS decoded a 10-bit ICC-tagged file about 64x too dark.
  // The rescale is a no-op for the 16-bit PNG path this transform was written
  // for, and gives every other depth the range the transform expects.
  const bool rescale = wide && bits < 16;
  const auto max_code = static_cast<std::uint32_t>((1U << bits) - 1U);

  // cmsDoTransform is documented as safe to call concurrently on one
  // transform, so the rows parallelise exactly like the matrix path. The
  // rescale buffer is per-row and therefore per-thread, which is why it is
  // allocated inside the body rather than shared.
  auto* handle = transform.get();
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const auto* row = pixels + static_cast<std::size_t>(y) * stride;
    float* target = out.pixels.data() + static_cast<std::size_t>(y) * width * 3;
    if (rescale) {
      std::vector<std::uint16_t> widened(static_cast<std::size_t>(width) * 3);
      const auto* source_samples = reinterpret_cast<const std::uint16_t*>(row);
      for (std::size_t i = 0; i < widened.size(); ++i) {
        widened[i] = static_cast<std::uint16_t>(
            (static_cast<std::uint32_t>(source_samples[i]) * 65535U + max_code / 2U) /
            max_code);
      }
      cmsDoTransform(handle, widened.data(), target, width);
    } else {
      cmsDoTransform(handle, row, target, width);
    }
    for (std::size_t i = 0; i < static_cast<std::size_t>(width) * 3; ++i) {
      // Out-of-gamut inputs can come back very slightly negative.
      target[i] = std::max(0.0F, target[i]);
    }
  });
}

// Fills the linear working image of a `DecodedImage`-shaped result. Callers own
// the metadata; this owns the pixels and nothing else, so the HEIF, AVIF, JPEG
// and PNG paths all reach the working space by the same route.
inline FloatImage interleaved_rgb_to_linear_p3(const std::uint8_t* pixels,
                                               std::uint32_t width,
                                               std::uint32_t height,
                                               std::size_t stride, int bits,
                                               const SourceColor& color) {
  if (!width || !height) throw std::runtime_error("decoded image has invalid dimensions");
  if (!pixels || bits < 1 || bits > 16) {
    throw std::runtime_error("decoded image has invalid RGB depth");
  }
  FloatImage linear(width, height, 3);
  if (!color.icc.empty()) {
    convert_rows_with_icc(pixels, width, height, stride, bits, color.icc, linear);
    return linear;
  }
  const bool wide = bits > 8;
  const float max_code = static_cast<float>((1U << bits) - 1U);
  parallel_for_rows(height, [&](const std::uint32_t y) {
    const auto* row = pixels + static_cast<std::size_t>(y) * stride;
    for (std::uint32_t x = 0; x < width; ++x) {
      std::array<float, 3> encoded{};
      for (unsigned c = 0; c < 3; ++c) {
        if (wide) {
          const std::size_t offset = (static_cast<std::size_t>(x) * 3 + c) * 2;
          const auto code = static_cast<std::uint16_t>(
              row[offset] | (static_cast<std::uint16_t>(row[offset + 1]) << 8));
          encoded[c] = code / max_code;
        } else {
          encoded[c] = row[static_cast<std::size_t>(x) * 3 + c] / max_code;
        }
      }
      const auto p3 = encoded_to_linear_p3(encoded[0], encoded[1], encoded[2],
                                           color.primaries, color.transfer);
      for (unsigned c = 0; c < 3; ++c) linear.at(x, y, c) = p3[c];
    }
  });
  return linear;
}

}  // namespace hyperdr::codec
