#pragma once
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/heif_reader.hpp"
namespace hyperdr::codec {
// Shared input/diagnostic reader. Returned pixels are oriented linear P3;
// gain-map code planes remain in their encoded domain until reconstruction.
DecodedImage decode_heic_bytes(const std::vector<std::uint8_t>&, const RawDecodeOptions&,
                               std::string_view path = {});
FloatImage decode_heif_gain(const HeifFile&, const HeifImagePlan&, unsigned channels);
}  // namespace hyperdr::codec
