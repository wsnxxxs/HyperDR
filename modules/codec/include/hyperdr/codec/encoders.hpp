#pragma once

// Writing a rendered image out, and reading it back to prove it decodes.
//
// Every conversion verifies its own output by default. An encoder that produces
// a structurally valid file no decoder will open is the failure mode this
// project most needs to catch before the user does, and the only reliable check
// is to decode what was just written.

#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/gainmap/types.hpp"

#include <cstdint>
#include <filesystem>
#include <vector>

namespace hyperdr {

// Display P3 SDR base plus an ISO 21496-1 gain map, related by a `tmap` derived
// item. `depth` selects the base image's bit depth; the gain map is always 8-bit.
[[nodiscard]] std::vector<std::uint8_t> encode_adaptive_heic(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    int depth);

// Backward-compatible JPEG/R, carrying both Ultra HDR v1 XMP and ISO 21496-1
// metadata. Requires an 8-bit base.
[[nodiscard]] std::vector<std::uint8_t> encode_ultrahdr_jpeg(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality);

// 10-bit BT.2100 PQ or HLG, in HEIF and in AVIF respectively. Both render from
// the reconstructed linear HDR image through the same transfer functions, so
// they differ only in container and codec.
[[nodiscard]] std::vector<std::uint8_t> encode_hdr_heic(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    HdrEncoding encoding);
[[nodiscard]] std::vector<std::uint8_t> encode_avif(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    HdrEncoding encoding);

// Decode-verification. Each throws with a specific reason on failure.
void verify_heic_decodable(const std::vector<std::uint8_t>& bytes);
void verify_heic_decodable(const std::vector<std::uint8_t>& bytes,
                           HdrEncoding encoding);
void verify_heic_decodable(const std::filesystem::path& input);
void verify_ultrahdr_jpeg(const std::vector<std::uint8_t>& bytes);
void verify_ultrahdr_jpeg(const std::filesystem::path& input);
void verify_avif_decodable(const std::vector<std::uint8_t>& bytes);

// Reconstructs a gain-map HEIC into a 16-bit linear TIFF, so the HDR rendition
// a display would show can be examined outside this tool.
void reconstruct_heic_to_tiff(const std::filesystem::path& input,
                              const std::filesystem::path& output);

}  // namespace hyperdr
