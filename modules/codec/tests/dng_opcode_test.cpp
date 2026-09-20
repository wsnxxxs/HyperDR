#include "../src/internal/dng_opcodes.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using hyperdr::codec::DngBadPixels;
using hyperdr::codec::DngGainMap;
using hyperdr::codec::DngRect;

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

// Opcode lists are big-endian whatever the file's byte order.
struct Bytes {
  std::vector<std::uint8_t> data;
  Bytes& u32(std::uint32_t value) {
    for (int shift = 24; shift >= 0; shift -= 8) data.push_back(static_cast<std::uint8_t>(value >> shift));
    return *this;
  }
  Bytes& f32(float value) {
    std::uint32_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    return u32(bits);
  }
  Bytes& f64(double value) {
    std::uint64_t bits = 0;
    std::memcpy(&bits, &value, sizeof(bits));
    for (int shift = 56; shift >= 0; shift -= 8) data.push_back(static_cast<std::uint8_t>(bits >> shift));
    return *this;
  }
  Bytes& append(const Bytes& more) {
    data.insert(data.end(), more.data.begin(), more.data.end());
    return *this;
  }
};

Bytes opcode(std::uint32_t id, std::uint32_t flags, const Bytes& parameters) {
  Bytes out;
  out.u32(id).u32(0x01030000U).u32(flags).u32(static_cast<std::uint32_t>(parameters.data.size()));
  return out.append(parameters);
}

Bytes opcode_list(const std::vector<Bytes>& opcodes) {
  Bytes out;
  out.u32(static_cast<std::uint32_t>(opcodes.size()));
  for (const auto& entry : opcodes) out.append(entry);
  return out;
}

Bytes gain_map_parameters(const DngGainMap& map) {
  Bytes out;
  out.u32(map.area.top).u32(map.area.left).u32(map.area.bottom).u32(map.area.right);
  out.u32(map.plane).u32(map.planes).u32(map.row_pitch).u32(map.col_pitch);
  out.u32(map.points_v).u32(map.points_h);
  out.f64(map.spacing_v).f64(map.spacing_h).f64(map.origin_v).f64(map.origin_h);
  out.u32(map.map_planes);
  for (const float gain : map.gains) out.f32(gain);
  return out;
}

// A 3 x 3 grid over the whole image whose gain is 1 + row + 10 * column, so
// bilinear interpolation of it is exact.
DngGainMap ramp_map() {
  DngGainMap map;
  map.points_v = 3;
  map.points_h = 3;
  map.spacing_v = 0.5;
  map.spacing_h = 0.5;
  for (int r = 0; r < 3; ++r) {
    for (int c = 0; c < 3; ++c) map.gains.push_back(1.0F + static_cast<float>(r) + 10.0F * static_cast<float>(c));
  }
  return map;
}

float gain_at(const DngGainMap& map, std::uint32_t row, std::uint32_t column, std::uint32_t height,
              std::uint32_t width) {
  using namespace hyperdr::codec;
  return dng_gain(map, dng_gain_axis(row, height, map.origin_v, map.spacing_v, map.points_v),
                  dng_gain_axis(column, width, map.origin_h, map.spacing_h, map.points_h), 0);
}

void test_parse() {
  using hyperdr::codec::parse_dng_opcode_list;
  auto map = ramp_map();
  map.area = {1, 2, 30, 40};
  map.row_pitch = 2;
  map.col_pitch = 2;
  const auto bytes = opcode_list({
      opcode(9, 0, gain_map_parameters(map)),
      opcode(1, 0, Bytes{}.u32(1)),  // WarpRectilinear, required
      opcode(3, 1, Bytes{}.u32(0)),  // FixVignetteRadial, optional
  });
  const auto list2 = parse_dng_opcode_list(bytes.data.data(), bytes.data.size(), 2);
  require(!list2.malformed && list2.gain_maps.size() == 1, "OpcodeList2 must yield its gain map");
  const auto& parsed = list2.gain_maps.front();
  require(parsed.area.top == 1 && parsed.area.left == 2 && parsed.area.bottom == 30 &&
              parsed.area.right == 40 && parsed.row_pitch == 2 && parsed.col_pitch == 2 &&
              parsed.points_v == 3 && parsed.points_h == 3 && parsed.spacing_v == 0.5 &&
              parsed.gains == map.gains,
          "a gain map must be read field for field, big-endian");
  require(list2.skipped_required == std::vector<std::uint32_t>{1},
          "a required opcode that is not applied must be reported, an optional one not");
  // A gain map is applied only from OpcodeList2, where its values are linear.
  const auto list3 = parse_dng_opcode_list(bytes.data.data(), bytes.data.size(), 3);
  require(list3.gain_maps.empty() && list3.skipped_required == std::vector<std::uint32_t>{9, 1},
          "a gain map outside OpcodeList2 must be reported as not applied");

  const auto list1_bytes = opcode_list({
      opcode(4, 0, Bytes{}.u32(0).u32(1)),
      opcode(5, 0, Bytes{}.u32(3).u32(1).u32(1).u32(7).u32(9).u32(0).u32(4).u32(12).u32(5)),
  });
  const auto list1 = parse_dng_opcode_list(list1_bytes.data.data(), list1_bytes.data.size(), 1);
  require(!list1.malformed && list1.bad_pixels.size() == 2 && list1.bad_pixels[0].constant == 0U &&
              list1.bad_pixels[0].bayer_phase == 1 && list1.bad_pixels[1].bayer_phase == 3 &&
              list1.bad_pixels[1].points.size() == 1 && list1.bad_pixels[1].points[0].first == 7 &&
              list1.bad_pixels[1].points[0].second == 9 && list1.bad_pixels[1].rects.size() == 1 &&
              list1.bad_pixels[1].rects[0].left == 4 && list1.bad_pixels[1].rects[0].bottom == 12,
          "bad-pixel opcodes must be read field for field");
}

void test_malformed() {
  using hyperdr::codec::parse_dng_opcode_list;
  const auto good = opcode(9, 0, gain_map_parameters(ramp_map()));
  auto truncated = opcode_list({good, good});
  truncated.data.resize(truncated.data.size() - 3);
  const auto cut = parse_dng_opcode_list(truncated.data.data(), truncated.data.size(), 2);
  require(cut.malformed && cut.gain_maps.size() == 1,
          "a list cut short must be malformed, keeping what came before");

  auto wrong_count = ramp_map();
  wrong_count.gains.pop_back();
  const auto short_map = opcode_list({opcode(9, 0, gain_map_parameters(wrong_count))});
  require(parse_dng_opcode_list(short_map.data.data(), short_map.data.size(), 2).malformed,
          "a gain map whose entries do not fill its grid must be malformed");
  auto overflowing = ramp_map();
  overflowing.points_v = 1U << 22U;
  overflowing.points_h = 1U << 22U;
  overflowing.map_planes = 1U << 20U;
  overflowing.gains.clear();
  const auto overflow_map = opcode_list({opcode(9, 0, gain_map_parameters(overflowing))});
  require(parse_dng_opcode_list(overflow_map.data.data(), overflow_map.data.size(), 2).malformed,
          "a gain map entry count must not wrap to zero and accept an empty grid");
  auto infinite = ramp_map();
  infinite.gains[4] = std::numeric_limits<float>::infinity();
  const auto bad_gain = opcode_list({opcode(9, 0, gain_map_parameters(infinite))});
  require(parse_dng_opcode_list(bad_gain.data.data(), bad_gain.data.size(), 2).malformed,
          "a non-finite gain must be malformed");
  auto no_spacing = ramp_map();
  no_spacing.spacing_h = 0.0;
  const auto zero_spacing = opcode_list({opcode(9, 0, gain_map_parameters(no_spacing))});
  require(parse_dng_opcode_list(zero_spacing.data.data(), zero_spacing.data.size(), 2).malformed,
          "a gain map without spacing must be malformed");
  const auto bad_phase = opcode_list({opcode(4, 0, Bytes{}.u32(0).u32(4))});
  require(parse_dng_opcode_list(bad_phase.data.data(), bad_phase.data.size(), 1).malformed,
          "a Bayer phase past 3 must be malformed");
  require(!parse_dng_opcode_list(nullptr, 0, 2).malformed, "no list is not a malformed list");
}

void test_gain_interpolation() {
  // The grid spans the whole image and pixel centres sit at (index + 0.5) /
  // length, as the DNG SDK's interpolator places them.
  const auto map = ramp_map();
  const auto near = [](float a, float b) { return std::abs(a - b) < 1.0e-4F; };
  require(near(gain_at(map, 0, 0, 100, 200), 1.0F + 0.01F + 0.05F), "top-left pixel centre");
  require(near(gain_at(map, 49, 99, 100, 200), 1.0F + 0.99F + 9.95F), "a pixel inside the first cell");
  require(near(gain_at(map, 99, 199, 100, 200), 1.0F + 1.99F + 19.95F), "bottom-right pixel centre");
  // Beyond the grid the nearest edge point holds.
  auto shifted = map;
  shifted.origin_v = 0.2;
  shifted.spacing_h = 0.2;
  require(near(gain_at(shifted, 10, 0, 100, 200), 1.0F + 0.0F + 0.125F),
          "rows before the grid's origin must take its first row");
  require(near(gain_at(shifted, 50, 199, 100, 200), 1.0F + 0.61F + 20.0F),
          "columns past the grid's last point must take that point");
  DngGainMap single;
  single.gains = {1.75F};
  require(near(gain_at(single, 3, 150, 100, 200), 1.75F), "a one-point map is one gain");
}

void test_area_and_pitch() {
  using hyperdr::codec::dng_gain_map_covers;
  DngGainMap map;
  map.area = {1, 1, 5, 7};
  map.row_pitch = 2;
  map.col_pitch = 2;
  require(dng_gain_map_covers(map, 1, 1, 0) && dng_gain_map_covers(map, 3, 5, 0),
          "pixels on the pitch inside the area must be covered");
  require(!dng_gain_map_covers(map, 2, 1, 0) && !dng_gain_map_covers(map, 1, 2, 0),
          "pixels off the pitch must not be covered");
  require(!dng_gain_map_covers(map, 5, 1, 0) && !dng_gain_map_covers(map, 1, 7, 0),
          "an area's bottom and right edges are exclusive");
  require(!dng_gain_map_covers(map, 1, 1, 1), "a map must cover only its planes");
  DngGainMap whole;
  require(dng_gain_map_covers(whole, 0, 0, 0) && dng_gain_map_covers(whole, 123, 456, 0),
          "an empty area is the whole image");

  // Android writes one map per Bayer site, each area ending one short of the
  // image; the last row and column of the odd sites are then left alone.
  const std::uint32_t height = 6;
  const std::uint32_t width = 8;
  std::vector<DngGainMap> sites(4);
  for (std::uint32_t i = 0; i < 4; ++i) {
    sites[i].area = {i / 2, i % 2, height - 1, width - 1};
    sites[i].row_pitch = 2;
    sites[i].col_pitch = 2;
  }
  for (std::uint32_t row = 0; row < height; ++row) {
    for (std::uint32_t column = 0; column < width; ++column) {
      const auto count = std::count_if(sites.begin(), sites.end(), [&](const DngGainMap& site) {
        return dng_gain_map_covers(site, row, column, 0);
      });
      const bool edge = (row == height - 1 && row % 2 == 1) || (column == width - 1 && column % 2 == 1);
      require(count == (edge ? 0 : 1), "per-site gain maps must cover each pixel once (row " +
                                           std::to_string(row) + ", column " + std::to_string(column) + ")");
    }
  }
}

// 8 x 8 Bayer samples: red 1000, green 2000, blue 3000, plus 10 per row and 1
// per column. Bayer phase 1 puts red at the top left.
std::vector<std::uint16_t> mosaic() {
  std::vector<std::uint16_t> samples(64);
  for (std::uint32_t row = 0; row < 8; ++row) {
    for (std::uint32_t column = 0; column < 8; ++column) {
      const bool green = ((row + column + 1U) & 1U) == 0U;
      const std::uint32_t base = green ? 2000U : (row % 2 == 0 ? 1000U : 3000U);
      samples[row * 8 + column] = static_cast<std::uint16_t>(base + row * 10U + column);
    }
  }
  return samples;
}

void test_bad_pixels_constant() {
  auto samples = mosaic();
  const auto at = [&](std::uint32_t row, std::uint32_t column) -> std::uint16_t& {
    return samples[row * 8 + column];
  };
  for (const auto& [row, column] : {std::pair{4U, 4U}, std::pair{4U, 6U}, std::pair{3U, 4U},
                                    std::pair{0U, 1U}, std::pair{0U, 0U}}) {
    at(row, column) = 0;
  }
  at(2, 5) = 2027;  // leaves (3, 4) a neighbour sum the mean has to round
  DngBadPixels fix;
  fix.constant = 0;
  fix.bayer_phase = 1;
  require(hyperdr::codec::fix_dng_bad_pixels(samples.data(), 8, 8, 8, fix), "a constant must be applied");
  // Red from the reds two away; a bad neighbour is left out, and one fixed in
  // the same pass does not count as good.
  require(at(4, 4) == (1024 + 1064 + 1042 + 1) / 3, "red pixel with a bad neighbour");
  require(at(4, 6) == (1026 + 1066 + 1) / 2, "red pixel at the right edge");
  // Green from its diagonals, rounded to nearest.
  require(at(3, 4) == (2023 + 2027 + 2043 + 2045 + 2) / 4, "green pixel");
  // Past an edge the last two rows repeat: (-1, 0) reads (1, 0).
  require(at(0, 1) == (2010 + 2012 + 2010 + 2012 + 2) / 4, "green pixel on the top edge");
  require(at(0, 0) == (1020 + 1002 + 1) / 2, "red corner pixel, repeating onto itself");
  require(at(5, 5) == 3055 && at(2, 2) == 1022, "good pixels must be left alone");
}

void test_bad_pixels_list() {
  auto samples = mosaic();
  const auto original = samples;
  const auto at = [&](std::uint32_t row, std::uint32_t column) { return samples[row * 8 + column]; };
  DngBadPixels fix;
  fix.bayer_phase = 1;
  fix.points = {{4, 4}};
  fix.rects = {DngRect{0, 2, 8, 3}};  // column 2
  require(hyperdr::codec::fix_dng_bad_pixels(samples.data(), 8, 8, 8, fix), "a list must be applied");
  require(at(4, 4) == (1024 + 1064 + 1046 + 1) / 3, "a listed red pixel skips its listed neighbour");
  require(at(3, 2) == (2021 + 2023 + 2041 + 2043 + 2) / 4, "a green pixel in a bad column");
  require(at(4, 2) == 1040, "a red pixel whose nearer same-colour neighbours are all listed");
  require(at(5, 5) == original[5 * 8 + 5] && at(4, 3) == original[4 * 8 + 3], "good pixels must be left alone");

  DngBadPixels huge;
  huge.bayer_phase = 1;
  huge.rects.assign(5000, DngRect{0, 0, 1, 1});
  auto untouched = original;
  require(!hyperdr::codec::fix_dng_bad_pixels(untouched.data(), 8, 8, 8, huge) && untouched == original,
          "an implausibly large list must be refused without changes");
}

}  // namespace

int main() {
  try {
    test_parse();
    test_malformed();
    test_gain_interpolation();
    test_area_and_pitch();
    test_bad_pixels_constant();
    test_bad_pixels_list();
    std::cout << "DNG opcode tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
