#include "../src/internal/raw_sensor_geometry.hpp"

#include <cstddef>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void check_storage(unsigned working_width, unsigned working_height,
                   unsigned raw_width, unsigned raw_height,
                   unsigned left, unsigned top, unsigned fuji_width,
                   unsigned expected_width, unsigned expected_height) {
  const auto sensor = hyperdr::codec::raw_sensor_geometry(working_width, working_height,
      raw_width, raw_height, left, top, fuji_width, false);
  require(sensor.left == left && sensor.top == top &&
              sensor.width == expected_width && sensor.height == expected_height,
          "Fuji calibration retained working dimensions instead of storage dimensions");
  // Checking each row's last index covers the complete contiguous row span.
  for (unsigned y = 0; y < sensor.height; ++y) {
    require(sensor.left + sensor.width <= raw_width, "calibration row crosses storage stride");
    const auto last = static_cast<std::size_t>(y + sensor.top) * raw_width +
                      sensor.left + sensor.width - 1;
    require(last < static_cast<std::size_t>(raw_width) * raw_height,
            "calibration index exceeds the unpacked sensor allocation");
  }
}
}

int main() {
  try {
    // Real LibRaw 0.22.1 open/unpack geometry: RAWSAMPLES.CH S2Pro and S3Pro.
    check_storage(3584, 3583, 2944, 2192, 32, 24, 1440, 2880, 2144);
    check_storage(3552, 3551, 4352, 1444, 48, 10, 2128, 4256, 1424);

    for (const bool layout : {false, true}) {
      constexpr unsigned f = 5;
      const unsigned stored_width = layout ? f : 2 * f;
      constexpr unsigned stored_height = 8;
      const auto sensor = hyperdr::codec::raw_sensor_geometry(20, 19,
          stored_width + 4, stored_height + 4, 2, 2, f, layout);
      require(sensor.width == stored_width && sensor.height == stored_height,
              "Fuji layout storage bounds differ from raw2image loop bounds");
      for (unsigned row = 0; row < stored_height; ++row)
        for (unsigned col = 0; col < stored_width; ++col) {
          // LibRaw copy_fuji_uncropped's forward mapping, independently of
          // the inverse helper under test. Both row/column parities occur.
          const int work_y = layout ? f - 1 - col + (row >> 1)
                                    : f - 1 + row - (col >> 1);
          const int work_x = layout ? col + ((row + 1) >> 1)
                                    : row + ((col + 1) >> 1);
          const auto site = hyperdr::codec::raw_sensor_site(sensor, work_x, work_y);
          require(site.first == static_cast<int>(col) && site.second == static_cast<int>(row),
                  "Fuji forward/inverse mapping lost a storage site");
        }
      const auto corner = hyperdr::codec::raw_sensor_site(sensor, 0, 0);
      require(corner == (layout ? std::pair<int, int>{2, -4} : std::pair<int, int>{4, -2}),
              "phantom diamond corner was clamped into the physical sensor");
      const auto odd_corner = hyperdr::codec::raw_sensor_site(sensor, 1, 0);
      require(odd_corner == (layout ? std::pair<int, int>{2, -3} : std::pair<int, int>{5, -2}),
              "signed odd support coordinate rounded incorrectly");
    }
    const auto bayer = hyperdr::codec::raw_sensor_geometry(96, 80, 104, 90, 4, 6, 0, false);
    require(bayer.width == 96 && bayer.height == 80 && bayer.left == 4 && bayer.top == 6,
            "ordinary Bayer visible geometry changed");
    require(hyperdr::codec::raw_sensor_site(bayer, 17, 23) == std::pair<int, int>{17, 23} &&
                hyperdr::codec::raw_sensor_site(bayer, -1, 0) == std::pair<int, int>{-1, 0},
            "ordinary Bayer coordinates were remapped or clamped");
    std::cout << "RAW sensor geometry passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
