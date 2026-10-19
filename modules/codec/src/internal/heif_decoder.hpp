#pragma once
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
namespace hyperdr::codec {
// Shared input/diagnostic reader. Returned pixels are oriented linear P3;
// gain-map code planes remain in their encoded domain until reconstruction.
DecodedImage decode_heic_bytes(const std::vector<std::uint8_t>&, const RawDecodeOptions&,
                               std::string_view path = {});
FloatImage decode_heif_gain(const HeifFile&, const HeifImagePlan&, unsigned channels);
// Write-back verification: VideoToolbox decodes every coded picture of the
// plan and each must match the plan's size, bit depth and chroma format. No
// RGB conversion and no whole-image buffer; memory stays at one tile.
void verify_heif_tiles(const HeifFile&, const HeifImagePlan&);
// Diagnostics (--reconstruct, display-curve): the SDR base as linear P3 and the
// encoded gain-map code plane, decoded by the same path as the input.
struct HeifAdaptiveParts {
  FloatImage base, gain;
  GainMapMetadata metadata;
};
HeifAdaptiveParts decode_heif_adaptive_parts(const std::vector<std::uint8_t>& bytes);
}  // namespace hyperdr::codec
