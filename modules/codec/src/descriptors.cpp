#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/codec/image_source.hpp"

#include <stdexcept>
#include "hyperdr/foundation/json.hpp"

namespace hyperdr {
UnsupportedFormat::UnsupportedFormat(std::string message, std::string feature)
    : std::runtime_error(std::move(message)), feature_(std::move(feature)) {}
std::string UnsupportedFormat::detail_json() const {
  if(feature_.empty())return {};
  json::Writer writer;return writer.begin_object().member("container","heif")
      .member("feature",feature_).end_object().take();
}
RawUnsupported::RawUnsupported(std::string kind, std::string camera)
    : std::runtime_error(kind=="dng" ? "This DNG cannot be decoded by this version of macOS"
        : camera.empty() ? "This camera RAW cannot be decoded by this version of macOS"
        : "RAW from "+camera+" is not supported by this version of macOS"),
      container(std::move(kind)), model(std::move(camera)) {}
std::string RawUnsupported::detail_json() const {
  json::Writer writer;return writer.begin_object().member("container",container)
      .member("model",model).end_object().take();
}


const char* hdr_encoding_name(HdrEncoding encoding) {
  switch (encoding) {
    case HdrEncoding::SdrJpeg: return "sdr-jpeg";
    case HdrEncoding::SdrTiff: return "sdr-tiff";
    case HdrEncoding::SdrDng: return "sdr-dng";
    case HdrEncoding::HdrTiff16: return "hdr-tiff-16";
    case HdrEncoding::HdrTiff32: return "hdr-tiff-32";
    case HdrEncoding::HdrDng: return "hdr-dng";
    case HdrEncoding::Adaptive: return "adaptive";
    case HdrEncoding::IsoGainMapJpeg: return "iso-gainmap-jpeg";
    case HdrEncoding::Pq: return "pq";
    case HdrEncoding::Hlg: return "hlg";
    case HdrEncoding::AvifPq: return "avif-pq";
    case HdrEncoding::AvifHlg: return "avif-hlg";
  }
  return "unknown";
}

std::optional<HdrEncoding> hdr_encoding_from_name(std::string_view name) {
  if (name == "sdr-jpeg") return HdrEncoding::SdrJpeg;
  if (name == "sdr-tiff") return HdrEncoding::SdrTiff;
  if (name == "sdr-dng") return HdrEncoding::SdrDng;
  if (name == "hdr-tiff-16") return HdrEncoding::HdrTiff16;
  if (name == "hdr-tiff-32") return HdrEncoding::HdrTiff32;
  if (name == "hdr-dng") return HdrEncoding::HdrDng;
  if (name == "adaptive") return HdrEncoding::Adaptive;
  // `ultrahdr` is the name the Web reference panel still sends. It is accepted
  // only until that panel is deleted (P2c); nothing ever writes it.
  if (name == "iso-gainmap-jpeg" || name == "ultrahdr") return HdrEncoding::IsoGainMapJpeg;
  if (name == "pq") return HdrEncoding::Pq;
  if (name == "hlg") return HdrEncoding::Hlg;
  if (name == "avif-pq") return HdrEncoding::AvifPq;
  if (name == "avif-hlg") return HdrEncoding::AvifHlg;
  return std::nullopt;
}

const char* hdr_encoding_extension(HdrEncoding encoding) {
  if (is_dng_encoding(encoding)) return ".dng";
  if (encoding == HdrEncoding::SdrTiff || is_linear_hdr_encoding(encoding)) return ".tif";
  if (encoding == HdrEncoding::IsoGainMapJpeg || encoding == HdrEncoding::SdrJpeg) return ".jpg";
  return is_avif_encoding(encoding) ? ".avif" : ".heic";
}


}  // namespace hyperdr
