#pragma once

// DNG opcode lists ("Opcode List Processing", DNG 1.3 and later), which LibRaw
// 0.22 reads out of a file as big-endian bytes and never applies. This decoder
// applies the two kinds cameras actually write before demosaic:
// FixBadPixelsConstant and FixBadPixelsList from OpcodeList1, on the raw
// sensor values, and GainMap from OpcodeList2, the lens-shading correction
// Android phones write, on linear values. Everything else is reported, if the
// file does not mark it optional. Pure data and arithmetic, so the tests can
// hold it to the DNG SDK without a camera file.

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <utility>
#include <vector>

namespace hyperdr::codec {

inline constexpr std::uint32_t kDngOpcodeFixBadPixelsConstant = 4;
inline constexpr std::uint32_t kDngOpcodeFixBadPixelsList = 5;
inline constexpr std::uint32_t kDngOpcodeGainMap = 9;
inline constexpr std::uint32_t kDngOpcodeOptional = 1;

// [top, bottom) x [left, right), as every DNG rectangle.
struct DngRect {
  std::uint32_t top{}, left{}, bottom{}, right{};
};

// GainMap: gains on a grid spread over the whole image, applied to every
// row_pitch-th row and col_pitch-th column of `area`, in the planes it names.
struct DngGainMap {
  DngRect area;
  std::uint32_t plane{0}, planes{1};
  std::uint32_t row_pitch{1}, col_pitch{1};
  std::uint32_t points_v{1}, points_h{1};
  double spacing_v{1.0}, spacing_h{1.0};
  double origin_v{0.0}, origin_h{0.0};
  std::uint32_t map_planes{1};
  std::vector<float> gains;  // points_v x points_h x map_planes, row major
};

// FixBadPixelsConstant (a raw value that marks a bad pixel) or
// FixBadPixelsList (listed pixels and rectangles), on a Bayer mosaic whose
// colours start at `bayer_phase`: 0 green in a red row, 1 red, 2 blue, 3 green
// in a blue row.
struct DngBadPixels {
  std::uint32_t bayer_phase{0};
  std::optional<std::uint32_t> constant;
  std::vector<std::pair<std::uint32_t, std::uint32_t>> points;  // row, column
  std::vector<DngRect> rects;
};

// One opcode list, reduced to what this decoder applies from that list.
struct DngOpcodeList {
  std::vector<DngGainMap> gain_maps;
  std::vector<DngBadPixels> bad_pixels;
  // Opcodes the file requires that this decoder does not apply.
  std::vector<std::uint32_t> skipped_required;
  bool malformed{false};
};

class DngOpcodeReader {
 public:
  DngOpcodeReader(const std::uint8_t* data, std::size_t size) : data_(data), size_(size) {}

  [[nodiscard]] std::size_t remaining() const { return size_ - at_; }
  [[nodiscard]] const std::uint8_t* position() const { return data_ + at_; }
  bool skip(std::size_t count) {
    if (remaining() < count) return false;
    at_ += count;
    return true;
  }
  bool u32(std::uint32_t& out) {
    if (remaining() < 4) return false;
    out = 0;
    for (std::size_t i = 0; i < 4; ++i) out = (out << 8U) | data_[at_ + i];
    at_ += 4;
    return true;
  }
  bool f32(float& out) {
    std::uint32_t bits = 0;
    if (!u32(bits)) return false;
    std::memcpy(&out, &bits, sizeof(out));
    return true;
  }
  bool f64(double& out) {
    if (remaining() < 8) return false;
    std::uint64_t bits = 0;
    for (std::size_t i = 0; i < 8; ++i) bits = (bits << 8U) | data_[at_ + i];
    at_ += 8;
    std::memcpy(&out, &bits, sizeof(out));
    return true;
  }

 private:
  const std::uint8_t* data_;
  std::size_t size_;
  std::size_t at_{0};
};

namespace dng_opcode_detail {

inline bool read_gain_map(DngOpcodeReader& in, DngGainMap& map) {
  constexpr std::uint64_t kMaximumEntries = 16ULL * 1024ULL * 1024ULL;
  if (!in.u32(map.area.top) || !in.u32(map.area.left) || !in.u32(map.area.bottom) ||
      !in.u32(map.area.right) || !in.u32(map.plane) || !in.u32(map.planes) ||
      !in.u32(map.row_pitch) || !in.u32(map.col_pitch) || !in.u32(map.points_v) ||
      !in.u32(map.points_h) || !in.f64(map.spacing_v) || !in.f64(map.spacing_h) ||
      !in.f64(map.origin_v) || !in.f64(map.origin_h) || !in.u32(map.map_planes)) {
    return false;
  }
  // A single point per axis has no spacing, as the SDK reads it.
  if (map.points_v == 1) {
    map.spacing_v = 1.0;
    map.origin_v = 0.0;
  }
  if (map.points_h == 1) {
    map.spacing_h = 1.0;
    map.origin_h = 0.0;
  }
  if (map.points_v < 1 || map.points_h < 1 || map.map_planes < 1 || map.row_pitch < 1 ||
      map.col_pitch < 1 || !(map.spacing_v > 0.0) || !(map.spacing_h > 0.0) ||
      !std::isfinite(map.spacing_v) || !std::isfinite(map.spacing_h) ||
      !std::isfinite(map.origin_v) || !std::isfinite(map.origin_h)) {
    return false;
  }
  const std::uint64_t points = static_cast<std::uint64_t>(map.points_v) * map.points_h;
  if (points > kMaximumEntries / map.map_planes) return false;
  const std::uint64_t entries = points * map.map_planes;
  if (in.remaining() != entries * 4U) return false;
  map.gains.resize(static_cast<std::size_t>(entries));
  for (auto& gain : map.gains) {
    if (!in.f32(gain) || !std::isfinite(gain)) return false;
  }
  return true;
}

inline bool read_bad_pixels_constant(DngOpcodeReader& in, DngBadPixels& fix) {
  std::uint32_t constant = 0;
  if (in.remaining() != 8 || !in.u32(constant) || !in.u32(fix.bayer_phase)) return false;
  fix.constant = constant;
  return fix.bayer_phase < 4;
}

inline bool read_bad_pixels_list(DngOpcodeReader& in, DngBadPixels& fix) {
  std::uint32_t points = 0;
  std::uint32_t rects = 0;
  if (!in.u32(fix.bayer_phase) || !in.u32(points) || !in.u32(rects) || fix.bayer_phase >= 4) {
    return false;
  }
  if (in.remaining() != static_cast<std::uint64_t>(points) * 8U + static_cast<std::uint64_t>(rects) * 16U) {
    return false;
  }
  fix.points.resize(points);
  for (auto& [row, column] : fix.points) {
    if (!in.u32(row) || !in.u32(column)) return false;
  }
  fix.rects.resize(rects);
  for (auto& rect : fix.rects) {
    if (!in.u32(rect.top) || !in.u32(rect.left) || !in.u32(rect.bottom) || !in.u32(rect.right)) {
      return false;
    }
  }
  return true;
}

}  // namespace dng_opcode_detail

// Parses OpcodeList1, 2 or 3 (`list`). A list that runs past its bytes or an
// opcode whose parameters do not add up stops the parse and marks the list
// malformed; what was read before it is kept.
[[nodiscard]] inline DngOpcodeList parse_dng_opcode_list(const std::uint8_t* data, std::size_t size,
                                                         int list) {
  DngOpcodeList out;
  if (data == nullptr || size == 0) return out;
  DngOpcodeReader in(data, size);
  std::uint32_t count = 0;
  if (!in.u32(count)) {
    out.malformed = true;
    return out;
  }
  for (std::uint32_t n = 0; n < count; ++n) {
    std::uint32_t id = 0, version = 0, flags = 0, byte_count = 0;
    if (!in.u32(id) || !in.u32(version) || !in.u32(flags) || !in.u32(byte_count) ||
        in.remaining() < byte_count) {
      out.malformed = true;
      return out;
    }
    DngOpcodeReader parameters(in.position(), byte_count);
    in.skip(byte_count);
    bool applied = false;
    bool valid = true;
    if (list == 2 && id == kDngOpcodeGainMap) {
      DngGainMap map;
      valid = dng_opcode_detail::read_gain_map(parameters, map);
      if (valid) out.gain_maps.push_back(std::move(map));
      applied = true;
    } else if (list == 1 && id == kDngOpcodeFixBadPixelsConstant) {
      DngBadPixels fix;
      valid = dng_opcode_detail::read_bad_pixels_constant(parameters, fix);
      if (valid) out.bad_pixels.push_back(std::move(fix));
      applied = true;
    } else if (list == 1 && id == kDngOpcodeFixBadPixelsList) {
      DngBadPixels fix;
      valid = dng_opcode_detail::read_bad_pixels_list(parameters, fix);
      if (valid) out.bad_pixels.push_back(std::move(fix));
      applied = true;
    }
    if (!valid) {
      out.malformed = true;
      return out;
    }
    if (!applied && (flags & kDngOpcodeOptional) == 0U) out.skipped_required.push_back(id);
  }
  return out;
}

// Whether a GainMap reaches (row, column) of its plane: inside the area, on
// its pitch. An empty area is the whole image.
[[nodiscard]] inline bool dng_gain_map_covers(const DngGainMap& map, std::uint32_t row,
                                              std::uint32_t column, std::uint32_t plane) {
  if (plane < map.plane || plane - map.plane >= map.planes) return false;
  const auto& area = map.area;
  if (area.top >= area.bottom || area.left >= area.right) {
    return row % map.row_pitch == 0 && column % map.col_pitch == 0;
  }
  return row >= area.top && row < area.bottom && column >= area.left && column < area.right &&
         (row - area.top) % map.row_pitch == 0 && (column - area.left) % map.col_pitch == 0;
}

// Where a pixel centre falls on one axis of the grid, as the SDK's
// interpolator places it: (index + 0.5) / length of the image, held to the
// first and last grid points.
struct DngGainAxis {
  std::uint32_t first{0};
  std::uint32_t second{0};
  float fraction{0.0F};
};

[[nodiscard]] inline DngGainAxis dng_gain_axis(std::uint32_t index, std::uint32_t length,
                                               double origin, double spacing,
                                               std::uint32_t points) {
  const double position = ((static_cast<double>(index) + 0.5) / length - origin) / spacing;
  if (!(position > 0.0)) return {};
  const std::uint32_t last = points - 1U;
  if (position >= static_cast<double>(last)) return {last, last, 0.0F};
  const auto first = static_cast<std::uint32_t>(position);
  return {first, first + 1U, static_cast<float>(position - first)};
}

[[nodiscard]] inline float dng_gain(const DngGainMap& map, const DngGainAxis& row,
                                    const DngGainAxis& column, std::uint32_t plane) {
  const std::uint32_t map_plane = std::min(plane, map.map_planes - 1U);
  const auto entry = [&](std::uint32_t r, std::uint32_t c) {
    return map.gains[(static_cast<std::size_t>(r) * map.points_h + c) * map.map_planes + map_plane];
  };
  const auto down = [&](std::uint32_t c) {
    return entry(row.first, c) * (1.0F - row.fraction) + entry(row.second, c) * row.fraction;
  };
  const float left = down(column.first);
  return left + (down(column.second) - left) * column.fraction;
}

namespace dng_opcode_detail {

inline bool is_green(const DngBadPixels& fix, std::uint32_t row, std::uint32_t column) {
  return ((row + column + fix.bayer_phase + (fix.bayer_phase >> 1U)) & 1U) == 0U;
}

// The SDK reads past an edge by repeating the last two rows or columns, which
// keeps the Bayer phase.
inline std::uint32_t repeat_edge(std::int64_t index, std::uint32_t length) {
  if (index < 0) return static_cast<std::uint32_t>(((index % 2) + 2) % 2);
  if (index >= length) {
    const std::int64_t base = static_cast<std::int64_t>(length) - 2;
    return static_cast<std::uint32_t>(base + (index - base) % 2);
  }
  return static_cast<std::uint32_t>(index);
}

}  // namespace dng_opcode_detail

// Fixes the pixels a FixBadPixelsConstant or FixBadPixelsList marks, in a
// Bayer mosaic of width x height samples, `stride` samples per row, all in
// the coordinates of the whole stored raw image. Replacements are computed
// from the original values of good pixels only, then written.
//
// A constant is fixed as the DNG SDK fixes it: a green pixel from its four
// diagonal neighbours, a red or blue one from the four two pixels away, bad
// neighbours left out. The SDK's FixBadPixelsList chooses among several
// directional interpolations; here a listed pixel takes the mean of the
// nearest ring of good same-colour pixels instead. Returns false, changing
// nothing, for a list too large to be a defect list (more than 4096
// rectangles or 16 million listed pixels).
inline bool fix_dng_bad_pixels(std::uint16_t* samples, std::uint32_t width, std::uint32_t height,
                               std::size_t stride, const DngBadPixels& fix) {
  using dng_opcode_detail::is_green;
  if (samples == nullptr || width < 2 || height < 2) return false;
  const auto at = [&](std::uint32_t row, std::uint32_t column) -> std::uint16_t& {
    return samples[static_cast<std::size_t>(row) * stride + column];
  };
  std::vector<std::pair<std::size_t, std::uint16_t>> replacements;

  if (fix.constant) {
    // No 16-bit sample can hold a larger constant, so nothing is marked.
    if (*fix.constant > 0xFFFFU) return true;
    const auto bad = static_cast<std::uint16_t>(*fix.constant);
    for (std::uint32_t row = 0; row < height; ++row) {
      for (std::uint32_t column = 0; column < width; ++column) {
        if (at(row, column) != bad) continue;
        const bool green = is_green(fix, row, column);
        const std::array<std::pair<int, int>, 4> offsets =
            green ? std::array<std::pair<int, int>, 4>{{{-1, -1}, {-1, 1}, {1, -1}, {1, 1}}}
                  : std::array<std::pair<int, int>, 4>{{{-2, 0}, {2, 0}, {0, -2}, {0, 2}}};
        std::uint32_t count = 0;
        std::uint32_t total = 0;
        for (const auto& [dy, dx] : offsets) {
          const auto value = at(dng_opcode_detail::repeat_edge(static_cast<std::int64_t>(row) + dy, height),
                                dng_opcode_detail::repeat_edge(static_cast<std::int64_t>(column) + dx, width));
          if (value == bad) continue;
          ++count;
          total += value;
        }
        if (count == 4) {
          replacements.emplace_back(static_cast<std::size_t>(row) * stride + column,
                                    static_cast<std::uint16_t>((total + 2U) >> 2U));
        } else if (count > 0) {
          replacements.emplace_back(static_cast<std::size_t>(row) * stride + column,
                                    static_cast<std::uint16_t>((total + (count >> 1U)) / count));
        }
      }
    }
  } else {
    constexpr std::uint64_t kMaximumListed = 16ULL * 1024ULL * 1024ULL;
    std::uint64_t listed_pixels = fix.points.size();
    std::vector<DngRect> rects;
    for (const auto& rect : fix.rects) {
      const DngRect clipped{rect.top, rect.left, std::min(rect.bottom, height), std::min(rect.right, width)};
      if (clipped.top >= clipped.bottom || clipped.left >= clipped.right) continue;
      listed_pixels += static_cast<std::uint64_t>(clipped.bottom - clipped.top) * (clipped.right - clipped.left);
      rects.push_back(clipped);
    }
    if (rects.size() > 4096U || listed_pixels > kMaximumListed) return false;
    auto points = fix.points;
    std::erase_if(points, [&](const auto& point) { return point.first >= height || point.second >= width; });
    std::sort(points.begin(), points.end());
    points.erase(std::unique(points.begin(), points.end()), points.end());
    const auto listed = [&](std::uint32_t row, std::uint32_t column) {
      if (std::binary_search(points.begin(), points.end(), std::make_pair(row, column))) return true;
      return std::any_of(rects.begin(), rects.end(), [&](const DngRect& rect) {
        return row >= rect.top && row < rect.bottom && column >= rect.left && column < rect.right;
      });
    };
    auto targets = points;
    for (const auto& rect : rects) {
      for (std::uint32_t row = rect.top; row < rect.bottom; ++row) {
        for (std::uint32_t column = rect.left; column < rect.right; ++column) {
          targets.emplace_back(row, column);
        }
      }
    }
    // Same-colour rings, nearest first.
    using Ring = std::vector<std::pair<int, int>>;
    const std::array<Ring, 4> green_rings{
        Ring{{-1, -1}, {-1, 1}, {1, -1}, {1, 1}}, Ring{{-2, 0}, {2, 0}, {0, -2}, {0, 2}},
        Ring{{-2, -2}, {-2, 2}, {2, -2}, {2, 2}},
        Ring{{-3, -1}, {-3, 1}, {3, -1}, {3, 1}, {-1, -3}, {1, -3}, {-1, 3}, {1, 3}}};
    const std::array<Ring, 4> other_rings{
        Ring{{-2, 0}, {2, 0}, {0, -2}, {0, 2}}, Ring{{-2, -2}, {-2, 2}, {2, -2}, {2, 2}},
        Ring{{-4, 0}, {4, 0}, {0, -4}, {0, 4}},
        Ring{{-4, -2}, {-4, 2}, {4, -2}, {4, 2}, {-2, -4}, {2, -4}, {-2, 4}, {2, 4}}};
    for (const auto& [row, column] : targets) {
      const auto& rings = is_green(fix, row, column) ? green_rings : other_rings;
      for (const auto& ring : rings) {
        std::uint32_t count = 0;
        std::uint32_t total = 0;
        for (const auto& [dy, dx] : ring) {
          const std::int64_t y = static_cast<std::int64_t>(row) + dy;
          const std::int64_t x = static_cast<std::int64_t>(column) + dx;
          if (y < 0 || x < 0 || y >= height || x >= width) continue;
          const auto ny = static_cast<std::uint32_t>(y);
          const auto nx = static_cast<std::uint32_t>(x);
          if (listed(ny, nx)) continue;
          ++count;
          total += at(ny, nx);
        }
        if (count > 0) {
          replacements.emplace_back(static_cast<std::size_t>(row) * stride + column,
                                    static_cast<std::uint16_t>((total + (count >> 1U)) / count));
          break;
        }
      }
    }
  }
  for (const auto& [index, value] : replacements) samples[index] = value;
  return true;
}

}  // namespace hyperdr::codec
