#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_transfer_curve() {
  for (const float x : {0.0F, 0.001F, 0.18F, 0.5F, 1.0F}) {
    require(std::abs(hyperdr::srgb_eotf(hyperdr::srgb_oetf(x)) - x) < 1.0e-5F,
            "sRGB transfer round trip failed");
  }
}

// BT.709 is not sRGB, and every CICP transfer of 1, 6, 14 or 15 used to be
// decoded as though it were. The gap is largest exactly where it hurts most:
// a code of 0.1 is 0.0224 in BT.709 and 0.0100 in sRGB, so the shadows came
// out 55% too dark before exposure, tone curve or gain map ever saw them.
void test_bt709_is_not_srgb() {
  require(std::abs(hyperdr::bt709_inverse_oetf(0.1F) - 0.02239F) < 1.0e-4F,
          "BT.709 decodes 0.1 to about 0.0224");
  require(std::abs(hyperdr::srgb_eotf(0.1F) - 0.01003F) < 1.0e-4F,
          "sRGB decodes 0.1 to about 0.0100");
  require(hyperdr::bt709_inverse_oetf(0.1F) > 2.0F * hyperdr::srgb_eotf(0.1F),
          "the two curves must not be treated as interchangeable");
}

void test_bt709_round_trip() {
  for (const float x : {0.0F, 0.001F, 0.018F, 0.081F, 0.18F, 0.5F, 1.0F}) {
    require(std::abs(hyperdr::bt709_inverse_oetf(hyperdr::bt709_oetf(x)) - x) < 1.0e-4F,
            "BT.709 transfer round trip failed");
  }
  require(hyperdr::bt709_inverse_oetf(0.0F) == 0.0F, "black stays black");
  require(std::abs(hyperdr::bt709_inverse_oetf(1.0F) - 1.0F) < 1.0e-5F,
          "white stays white");
  // Monotonic across the segment boundary at 4.5 * beta.
  float previous = -1.0F;
  for (int i = 0; i <= 1000; ++i) {
    const float value = hyperdr::bt709_inverse_oetf(static_cast<float>(i) / 1000.0F);
    require(value >= previous, "the inverse OETF must be monotonic");
    previous = value;
  }
}

}  // namespace

int main() {
  try {
    test_transfer_curve();
    test_bt709_is_not_srgb();
    test_bt709_round_trip();
    std::cout << "transfer tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
