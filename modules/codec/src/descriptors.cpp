#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/codec/image_source.hpp"

#include <stdexcept>

namespace hyperdr {

const char* hdr_encoding_name(HdrEncoding encoding) {
  switch (encoding) {
    case HdrEncoding::Adaptive: return "adaptive";
    case HdrEncoding::UltraHdr: return "ultrahdr";
    case HdrEncoding::Pq: return "pq";
    case HdrEncoding::Hlg: return "hlg";
    case HdrEncoding::AvifPq: return "avif-pq";
    case HdrEncoding::AvifHlg: return "avif-hlg";
  }
  return "unknown";
}

std::optional<HdrEncoding> hdr_encoding_from_name(std::string_view name) {
  // The aliases are the names earlier versions accepted. Keeping them costs one
  // line each and avoids breaking scripts and stored presets.
  if (name == "adaptive" || name == "gain-map") return HdrEncoding::Adaptive;
  if (name == "ultrahdr" || name == "ultra-hdr" || name == "jpegr") {
    return HdrEncoding::UltraHdr;
  }
  if (name == "pq") return HdrEncoding::Pq;
  if (name == "hlg") return HdrEncoding::Hlg;
  if (name == "avif-pq" || name == "avif") return HdrEncoding::AvifPq;
  if (name == "avif-hlg") return HdrEncoding::AvifHlg;
  return std::nullopt;
}

const char* hdr_encoding_extension(HdrEncoding encoding) {
  if (encoding == HdrEncoding::UltraHdr) return ".jpg";
  return is_avif_encoding(encoding) ? ".avif" : ".heic";
}

const char* highlight_recovery_name(HighlightRecovery mode) {
  switch (mode) {
    case HighlightRecovery::Clip: return "clip";
    case HighlightRecovery::Unclip: return "unclip";
    case HighlightRecovery::Blend: return "blend";
    case HighlightRecovery::Reconstruct: return "reconstruct";
  }
  return "unknown";
}

std::optional<HighlightRecovery> highlight_recovery_from_name(std::string_view name) {
  if (name == "blend") return HighlightRecovery::Blend;
  if (name == "reconstruct") return HighlightRecovery::Reconstruct;
  if (name == "clip") return HighlightRecovery::Clip;
  if (name == "unclip") return HighlightRecovery::Unclip;
  return std::nullopt;
}

const char* bayer_pattern_name(BayerPattern pattern) {
  switch (pattern) {
    case BayerPattern::RGGB: return "RGGB";
    case BayerPattern::BGGR: return "BGGR";
    case BayerPattern::GRBG: return "GRBG";
    case BayerPattern::GBRG: return "GBRG";
    case BayerPattern::Unknown: break;
  }
  return "unknown";
}

FloatImage pack_bayer(const RawMosaic& mosaic) {
  mosaic.samples.require_consistent("RAW mosaic");
  if (mosaic.pattern == BayerPattern::Unknown) {
    throw std::invalid_argument("cannot pack an unknown Bayer pattern");
  }
  if ((mosaic.samples.width & 1U) != 0 || (mosaic.samples.height & 1U) != 0) {
    throw std::invalid_argument("Bayer packing requires even RAW dimensions");
  }

  struct Offset {
    std::uint32_t x;
    std::uint32_t y;
  };
  std::array<Offset, 4> offsets{};  // R, Gr, Gb, B
  switch (mosaic.pattern) {
    case BayerPattern::RGGB:
      offsets = {{{0, 0}, {1, 0}, {0, 1}, {1, 1}}};
      break;
    case BayerPattern::BGGR:
      offsets = {{{1, 1}, {0, 1}, {1, 0}, {0, 0}}};
      break;
    case BayerPattern::GRBG:
      offsets = {{{1, 0}, {0, 0}, {1, 1}, {0, 1}}};
      break;
    case BayerPattern::GBRG:
      offsets = {{{0, 1}, {1, 1}, {0, 0}, {1, 0}}};
      break;
    case BayerPattern::Unknown:
      throw std::invalid_argument("cannot pack an unknown Bayer pattern");
  }

  FloatImage packed(mosaic.samples.width / 2, mosaic.samples.height / 2, 4);
  for (std::uint32_t y = 0; y < packed.height; ++y) {
    for (std::uint32_t x = 0; x < packed.width; ++x) {
      for (std::uint32_t c = 0; c < 4; ++c) {
        packed.at(x, y, c) = mosaic.samples.at(
            x * 2U + offsets[c].x, y * 2U + offsets[c].y, 0);
      }
    }
  }
  return packed;
}

}  // namespace hyperdr
