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

// The BT.2100 pair used to be written twice: forwards here, backwards inside
// the raster decoder. Reading back a PQ or HLG file this project had just
// written therefore depended on two transcriptions of the same standard
// agreeing, and nothing checked that they did. They are now one pair, and this
// is the check.
void test_bt2100_round_trip() {
  for (const float x : {0.0F, 0.001F, 0.05F, 0.18F, 0.5F, 1.0F, 2.0F, 4.0F, 10.0F}) {
    const float pq = hyperdr::pq_eotf(hyperdr::pq_oetf(x));
    require(std::abs(pq - x) < 1.0e-3F * std::max(1.0F, x),
            "PQ transfer round trip failed");
  }
  // HLG's nominal peak is 1000 nits against a 203-nit reference white, so
  // anything above 1000/203 is outside what the curve can carry and the encoder
  // clamps it. Round-tripping is only meaningful below that.
  for (const float x : {0.0F, 0.001F, 0.05F, 0.18F, 0.5F, 1.0F, 2.0F, 4.9F}) {
    const float hlg = hyperdr::hlg_inverse_oetf(hyperdr::hlg_oetf(x));
    require(std::abs(hlg - x) < 1.0e-3F * std::max(1.0F, x),
            "HLG transfer round trip failed");
  }
  // Diffuse white is the anchor both curves are defined against: BT.2408 puts
  // graphics white at 203 nits, and HLG places it at signal level 0.75.
  require(std::abs(hyperdr::hlg_oetf(1.0F) - 0.75F) < 1.0e-3F,
          "HLG must place diffuse white at signal 0.75");
  require(std::abs(hyperdr::pq_eotf(hyperdr::pq_oetf(1.0F)) - 1.0F) < 1.0e-4F,
          "PQ must return diffuse white unchanged");
  float previous = -1.0F;
  for (int i = 0; i <= 1000; ++i) {
    const float value = hyperdr::pq_eotf(static_cast<float>(i) / 1000.0F);
    require(value >= previous, "the PQ EOTF must be monotonic");
    previous = value;
  }
  previous = -1.0F;
  for (int i = 0; i <= 1000; ++i) {
    const float value = hyperdr::hlg_inverse_oetf(static_cast<float>(i) / 1000.0F);
    require(value >= previous, "the HLG inverse OETF must be monotonic");
    previous = value;
  }
}

}  // namespace

int main() {
  try {
    test_transfer_curve();
    test_bt709_is_not_srgb();
    test_bt709_round_trip();
    test_bt2100_round_trip();
    std::cout << "transfer tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
