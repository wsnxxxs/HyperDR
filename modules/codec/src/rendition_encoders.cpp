#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/gainmap/rendition.hpp"
namespace hyperdr {
std::vector<std::uint8_t> encode_hdr_heic(const GainMapResult& images,
    const PhotoMetadata& metadata, int quality, HdrEncoding encoding) {
  return encode_hdr_heic(renditions_from_gain_map(images),metadata,quality,encoding);
}
std::vector<std::uint8_t> encode_avif(const GainMapResult& images,
    const PhotoMetadata& metadata, int quality, HdrEncoding encoding) {
  return encode_avif(renditions_from_gain_map(images),metadata,quality,encoding);
}
}  // namespace hyperdr
