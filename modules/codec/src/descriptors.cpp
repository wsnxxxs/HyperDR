#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/codec/image_source.hpp"

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

}  // namespace hyperdr
