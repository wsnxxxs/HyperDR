#pragma once

// Which SDR or HDR representation to write.
//
// The choice determines container, codec, bit depth and transfer function
// together, because those four are not independently selectable in practice: a
// gain-map HEIC is 8-bit Display P3 plus a map, and a BT.2100 rendition is
// 10-bit Rec.2020 whether it lands in HEIF or AVIF.

#include <optional>
#include <string_view>

namespace hyperdr {


enum class OutputEncoding {
  // Display P3 SDR base plus an ISO 21496-1 gain map, in HEIF. The
  // compatibility-first default: it renders as an ordinary photo everywhere and
  // as HDR where the gain map is understood.
  Adaptive,
  // The same idea in JPEG: an SDR primary plus an ISO 21496-1 gain map, no XMP.
  IsoGainMapJpeg,
  // BT.2100 samples, 10-bit Rec.2020, in HEIF.
  Pq,
  Hlg,
  // The same two renditions in AVIF. Same pixels, different container and codec.
  AvifPq,
  AvifHlg,
  // Ordinary JPEG, sRGB by default or Display P3, without a gain map.
  SdrJpeg,
  // Lossless 16-bit TIFF, Display P3 by default or sRGB.
  SdrTiff,
  // Lossless linear DNG (LinearRaw), 16-bit unsigned: the SDR rendition.
  SdrDng,
  // The reconstructed HDR rendition itself, linear: IEEE float samples with SDR
  // white at 1.0 and highlights above it, 16-bit (half) or 32-bit TIFF.
  HdrTiff16,
  HdrTiff32,
  // The same rendition as a 16-bit LinearRaw DNG, scaled under the white level
  // and raised again by BaselineExposure. Apple's raw engine reads no float DNG.
  HdrDng,
};

using HdrEncoding = OutputEncoding;  // Source compatibility for existing clients.

[[nodiscard]] constexpr bool is_sdr_encoding(OutputEncoding e) {
  return e == OutputEncoding::SdrJpeg || e == OutputEncoding::SdrTiff || e == OutputEncoding::SdrDng;
}
// Linear samples of the HDR rendition itself: no gain map, no transfer curve.
[[nodiscard]] constexpr bool is_linear_hdr_encoding(OutputEncoding e) {
  return e == OutputEncoding::HdrTiff16 || e == OutputEncoding::HdrTiff32 || e == OutputEncoding::HdrDng;
}
[[nodiscard]] constexpr bool is_dng_encoding(OutputEncoding e) {
  return e == OutputEncoding::SdrDng || e == OutputEncoding::HdrDng;
}
// TIFF and DNG: every sample written as rendered, without lossy coding.
[[nodiscard]] constexpr bool is_lossless_encoding(OutputEncoding e) {
  return e == OutputEncoding::SdrTiff || is_dng_encoding(e) || is_linear_hdr_encoding(e);
}
[[nodiscard]] constexpr bool is_gain_map_encoding(OutputEncoding e) { return e == OutputEncoding::Adaptive || e == OutputEncoding::IsoGainMapJpeg; }

// True for encodings whose sample values are BT.2100 rather than a Display-P3
// SDR base plus a gain map.
[[nodiscard]] constexpr bool is_bt2100_encoding(HdrEncoding encoding) {
  return encoding == HdrEncoding::Pq || encoding == HdrEncoding::Hlg ||
         encoding == HdrEncoding::AvifPq || encoding == HdrEncoding::AvifHlg;
}

[[nodiscard]] constexpr bool is_avif_encoding(HdrEncoding encoding) {
  return encoding == HdrEncoding::AvifPq || encoding == HdrEncoding::AvifHlg;
}

[[nodiscard]] constexpr bool is_hlg_encoding(HdrEncoding encoding) {
  return encoding == HdrEncoding::Hlg || encoding == HdrEncoding::AvifHlg;
}

// HLG's useful range above 203-nit diffuse white at the standard 1000-nit
// system OOTF. Requesting more is a configuration error, not something to
// silently clamp.
inline constexpr float kHlgHeadroomStops = 2.3F;

[[nodiscard]] const char* hdr_encoding_name(HdrEncoding encoding);
// Accepts the canonical name, and `ultrahdr` for `IsoGainMapJpeg` until the
// Web reference panel is deleted (P2c). Returns nullopt for anything else so
// the caller can report it.
[[nodiscard]] std::optional<HdrEncoding> hdr_encoding_from_name(std::string_view name);
// The extension a conversion writes for this encoding, including the dot.
[[nodiscard]] const char* hdr_encoding_extension(HdrEncoding encoding);

}  // namespace hyperdr
