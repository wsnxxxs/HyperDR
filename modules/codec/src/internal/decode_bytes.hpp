#pragma once

// The decoders, entered with the file already in memory.
//
// Every decoder used to open its own copy of the input, and the probes that
// choose between them opened one more. A plain JPEG was read twice --
// `is_ultrahdr_jpeg_file` read all of it only to answer no, and `decode_jpeg`
// then read it again -- and an Ultra HDR JPEG was read twice for the same
// reason. `decode_image` now performs the one read and hands the bytes to
// whichever of these the signature selected.
//
// These take a vector rather than a span because the HEIF container helpers in
// `hyperdr::container` do, and shipping the same buffer through unchanged is
// the entire point of the header.

#include "hyperdr/codec/image_source.hpp"

#include <cstdint>
#include <vector>

namespace hyperdr::codec {

// Ultra HDR JPEG/R: true when the file carries a gain map libultrahdr can read.
[[nodiscard]] bool is_ultrahdr_bytes(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] DecodedImage decode_ultrahdr_bytes(
    const std::vector<std::uint8_t>& bytes,
    ColorGamut default_gamut = ColorGamut::kSrgb);

// AVIF is a member of the same box family as HEIF, so this answers which of the
// two an ISO base media file actually is.
[[nodiscard]] bool is_avif_bytes(const std::vector<std::uint8_t>& bytes);
// `preview_max_edge` is the same hint RawDecodeOptions carries: zero decodes
// at full size, non-zero lets the decoder stop early. See image_source.hpp.
[[nodiscard]] DecodedImage decode_avif_bytes(const std::vector<std::uint8_t>& bytes,
                                            std::uint32_t preview_max_edge,
                                            ColorGamut default_gamut =
                                                ColorGamut::kSrgb);

}  // namespace hyperdr::codec
