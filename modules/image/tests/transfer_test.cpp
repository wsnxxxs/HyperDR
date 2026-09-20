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
  // clamps it. Round-tripping is only meaningful below that, for neutrals and
  // for colours whose brightest channel still fits after the inverse OOTF.
  for (const float x : {0.0F, 0.001F, 0.05F, 0.18F, 0.5F, 1.0F, 2.0F, 4.9F}) {
    const auto hlg = hyperdr::hlg_decode(hyperdr::hlg_encode({x, x, x}));
    for (const float channel : hlg) {
      require(std::abs(channel - x) < 1.0e-3F * std::max(1.0F, x),
              "HLG transfer round trip failed");
    }
  }
  for (const auto& colour : {std::array<float, 3>{0.9F, 0.2F, 0.05F},
                             std::array<float, 3>{0.01F, 0.3F, 0.02F},
                             std::array<float, 3>{2.0F, 1.5F, 0.4F}}) {
    const auto hlg = hyperdr::hlg_decode(hyperdr::hlg_encode(colour));
    for (std::size_t c = 0; c < 3; ++c) {
      require(std::abs(hlg[c] - colour[c]) < 1.0e-3F * std::max(1.0F, colour[c]),
              "HLG colour round trip failed");
    }
  }
  // Diffuse white is the anchor both curves are defined against: BT.2408 puts
  // graphics white at 203 nits, and HLG places it at signal level 0.75.
  require(std::abs(hyperdr::hlg_encode({1.0F, 1.0F, 1.0F})[0] - 0.75F) < 1.0e-3F,
          "HLG must place diffuse white at signal 0.75");
  // BT.2100's OOTF: display light is the scene colour scaled by the scene
  // luminance to the power gamma - 1, so a decoded colour keeps the channel
  // ratios of its scene light and its luminance is Ys ^ 1.2 of the peak.
  const std::array<float, 3> signal{0.8F, 0.4F, 0.2F};
  const auto display = hyperdr::hlg_decode(signal);
  std::array<float, 3> scene{};
  for (std::size_t c = 0; c < 3; ++c) scene[c] = hyperdr::hlg_inverse_oetf_scene(signal[c]);
  const float scene_y = 0.2627F * scene[0] + 0.6780F * scene[1] + 0.0593F * scene[2];
  const float display_y = 0.2627F * display[0] + 0.6780F * display[1] + 0.0593F * display[2];
  require(std::abs(display_y - std::pow(scene_y, 1.2F) * 1000.0F / 203.0F) < 1.0e-4F,
          "the HLG OOTF must raise scene luminance to the system gamma");
  require(std::abs(display[0] / display[1] - scene[0] / scene[1]) < 1.0e-4F &&
              std::abs(display[2] / display[1] - scene[2] / scene[1]) < 1.0e-4F,
          "the HLG OOTF must keep the scene colour's channel ratios");
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
    const float value = hyperdr::hlg_inverse_oetf_scene(static_cast<float>(i) / 1000.0F);
    require(value >= previous, "the HLG inverse OETF must be monotonic");
    previous = value;
  }
}

void test_hlg_saturated_highlight_preserves_luminance() {
  const auto blue = hyperdr::p3_to_rec2020(
      0.0F, 0.0F, hyperdr::kHlgNominalPeakNits / hyperdr::kReferenceWhiteNits);
  const auto luminance = [](const std::array<float, 3>& rgb) {
    return 0.2627F * rgb[0] + 0.6780F * rgb[1] + 0.0593F * rgb[2];
  };
  const float before_y = luminance(blue);
  const auto encoded = hyperdr::hlg_encode(blue);
  const auto decoded = hyperdr::hlg_decode(encoded);
  for (const float value : encoded) {
    require(value >= 0.0F && value <= 1.0F + 1.0e-6F,
            "HLG volume fitting must produce legal signal values");
  }
  require(std::abs(luminance(decoded) - before_y) < 1.0e-5F,
          "HLG saturated blue must not lose luminance to scene-channel clipping");
  require(decoded[2] < blue[2] && decoded[0] > blue[0] && decoded[1] > blue[1],
          "an unrepresentable HLG highlight must reduce chroma toward neutral");

  // A colour whose scene channels already fit must keep the original OOTF,
  // without receiving the highlight's chroma reduction.
  const std::array<float, 3> inside{2.0F, 1.5F, 0.4F};
  const auto kept = hyperdr::hlg_encode(inside);
  const double y = luminance(inside) * hyperdr::kReferenceWhiteNits /
                   hyperdr::kHlgNominalPeakNits;
  const double factor = std::pow(y, 1.0 / hyperdr::kHlgSystemGamma - 1.0);
  for (std::size_t c = 0; c < 3; ++c) {
    const auto expected = hyperdr::hlg_oetf_scene(static_cast<float>(
        inside[c] * hyperdr::kReferenceWhiteNits / hyperdr::kHlgNominalPeakNits * factor));
    require(std::abs(kept[c] - expected) < 1.0e-6F,
            "HLG volume fitting changed an already representable colour");
  }
}

}  // namespace

int main() {
  try {
    test_transfer_curve();
    test_bt709_is_not_srgb();
    test_bt709_round_trip();
    test_bt2100_round_trip();
    test_hlg_saturated_highlight_preserves_luminance();
    std::cout << "transfer tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
