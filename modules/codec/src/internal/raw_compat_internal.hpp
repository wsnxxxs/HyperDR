#pragma once

#include <libraw/libraw.h>

#include <array>
#include <cstdint>

namespace hyperdr::raw_compat_internal {

// Internal entry shared with the small CFA-pattern unit test.
bool bayer_pattern(const LibRaw& raw, std::array<std::uint8_t, 4>* output = nullptr);

}  // namespace hyperdr::raw_compat_internal
