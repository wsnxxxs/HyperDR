#pragma once

#include <cstdint>

namespace hyperdr::codec {

inline constexpr std::uint64_t kMaxRasterPixels = 32ULL * 1024ULL * 1024ULL;
inline constexpr std::uint64_t kMaxRasterPeakBytes =
    512ULL * 1024ULL * 1024ULL;

// RAW has a different contract from ordinary compressed rasters. A full export
// must preserve the input's photographic dimensions, so its admission limit is
// based on the largest capture this application intentionally supports rather
// than on the temporary working-set estimate below. Sony's A7R V 16-frame Pixel
// Shift composite is 19008 x 12672 (240.8 MP).
inline constexpr std::uint64_t kMaxRawPixels =
    19008ULL * 12672ULL;

[[nodiscard]] inline bool pixel_count_ok(std::uint64_t width,
                                         std::uint64_t height,
                                         std::uint64_t limit) {
  return width != 0 && height != 0 && width <= limit / height;
}

[[nodiscard]] inline bool raw_input_budget_ok(std::uint64_t width,
                                              std::uint64_t height) {
  return pixel_count_ok(width, height, kMaxRawPixels);
}

// Keep this non-throwing so it is also safe to use at the C decoder boundaries
// in raster_decoder.cpp, where exceptions must not unwind through codec frames.
[[nodiscard]] inline bool raster_budget_ok(std::uint64_t width,
                                           std::uint64_t height) {
  if (!pixel_count_ok(width, height, kMaxRasterPixels)) return false;
  const auto pixels = width * height;
  return pixels <= kMaxRasterPixels &&
         pixels <= kMaxRasterPeakBytes / 15U;
}

}  // namespace hyperdr::codec
