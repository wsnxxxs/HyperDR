#pragma once

// Which HDR representation to write.
//
// The choice determines container, codec, bit depth and transfer function
// together, because those four are not independently selectable in practice: a
// gain-map HEIC is 8-bit Display P3 plus a map, and a BT.2100 rendition is
// 10-bit Rec.2020 whether it lands in HEIF or AVIF.

#include <optional>
#include <string_view>

namespace hyperdr {

enum class HdrEncoding {
  // Display P3 SDR base plus an ISO 21496-1 gain map, in HEIF. The
  // compatibility-first default: it renders as an ordinary photo everywhere and
  // as HDR where the gain map is understood.
  Adaptive,
  // The same idea in JPEG: a backward-compatible SDR primary plus a gain map.
  UltraHdr,
  // BT.2100 samples, 10-bit Rec.2020, in HEIF.
  Pq,
  Hlg,
  // The same two renditions in AVIF. Same pixels, different container and codec.
  AvifPq,
  AvifHlg,
};

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
// Accepts the canonical name and the historical aliases. Returns nullopt for
// anything else so the caller can report it.
[[nodiscard]] std::optional<HdrEncoding> hdr_encoding_from_name(std::string_view name);
// The extension a conversion writes for this encoding, including the dot.
[[nodiscard]] const char* hdr_encoding_extension(HdrEncoding encoding);

}  // namespace hyperdr
