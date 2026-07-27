#pragma once

// LibRaw is used by exactly one translation unit, and reached from exactly one
// other: the format dispatcher in raster_decoder.cpp. This declaration used to
// be written out by hand there, so the two files could disagree about the
// signature and only the linker would notice.

#include "hyperdr/codec/image_source.hpp"

#include <filesystem>

namespace hyperdr::codec {

[[nodiscard]] DecodedImage decode_raw(const std::filesystem::path& path,
                                      const RawDecodeOptions& options);
}  // namespace hyperdr::codec
