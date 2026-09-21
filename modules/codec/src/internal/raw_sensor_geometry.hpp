#pragma once

#include <algorithm>
#include <stdexcept>
#include <utility>

namespace hyperdr::codec {

// The unpacked sensor rectangle is distinct from LibRaw's diamond-shaped
// working raster on Super CCD cameras. Coordinates here precede raw2image.
struct RawSensorGeometry {
  unsigned left{}, top{}, width{}, height{}, fuji_width{};
  bool fuji_layout{};
};

inline RawSensorGeometry raw_sensor_geometry(unsigned width, unsigned height,
    unsigned raw_width, unsigned raw_height, unsigned left, unsigned top,
    unsigned fuji_width, bool fuji_layout) {
  if (left >= raw_width || top >= raw_height)
    throw std::invalid_argument("RAW visible origin is outside the sensor buffer");
  if (fuji_width) {
    // Match LibRaw::copy_fuji_uncropped's storage-domain loop bounds.
    width = fuji_width << !fuji_layout;
    height = top < raw_height - top ? raw_height - 2 * top : 0;
  }
  width = std::min(width, raw_width - left);
  height = std::min(height, raw_height - top);
  if (!width || !height)
    throw std::invalid_argument("RAW visible sensor area is empty");
  return {left, top, width, height, fuji_width, fuji_layout};
}

// Inverse of LibRaw's storage-to-diamond mapping. Keep signed coordinates:
// blank corners of the working raster lie outside the physical sensor.
inline std::pair<int, int> raw_sensor_site(const RawSensorGeometry& sensor,
                                          int x, int y) {
  if (!sensor.fuji_width) return {x, y};
  const auto ceil_half = [](int value) { return value / 2 + (value > 0 && value % 2); };
  const int f = static_cast<int>(sensor.fuji_width);
  if (sensor.fuji_layout) {
    const int row = y + x - f + 1;
    return {x - ceil_half(row), row};
  }
  const int col = x - y + f - 1;
  return {col, x - ceil_half(col)};
}

}  // namespace hyperdr::codec
