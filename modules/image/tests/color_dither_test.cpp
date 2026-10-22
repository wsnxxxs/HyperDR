#include "hyperdr/image/color.hpp"
#include "hyperdr/image/transfer.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
}  // namespace

int main() {
  try {
    using namespace hyperdr;

    // Wide-gamut detection: a saturated P3 green is outside Rec.709; neutral and
    // moderately saturated in-gamut colours are not.
    require(is_outside_rec709(0.0F, 0.6F, 0.0F),
            "saturated P3 green not flagged outside Rec.709");
    require(!is_outside_rec709(0.4F, 0.4F, 0.4F),
            "neutral grey wrongly flagged outside Rec.709");
    require(!is_outside_rec709(0.5F, 0.2F, 0.1F),
            "in-gamut warm colour wrongly flagged outside Rec.709");

    // Oklab: P3 white is L = 1 with no chroma, and the pair round-trips.
    const auto white_lab = linear_p3_to_oklab(1.0F, 1.0F, 1.0F);
    require(std::abs(white_lab[0] - 1.0F) < 1.0e-3F && std::abs(white_lab[1]) < 1.0e-3F &&
                std::abs(white_lab[2]) < 1.0e-3F,
            "P3 white is not Oklab white");
    const auto lab = linear_p3_to_oklab(0.9F, 0.05F, 0.2F);
    const auto lab_back = oklab_to_linear_p3(lab[0], lab[1], lab[2]);
    require(std::abs(lab_back[0] - 0.9F) < 1.0e-5F && std::abs(lab_back[1] - 0.05F) < 1.0e-5F &&
                std::abs(lab_back[2] - 0.2F) < 1.0e-5F,
            "Oklab is not the inverse of linear P3 to Oklab");

    // Gamut fitting: a colour inside is returned bit for bit; one outside lands
    // inside at its own luminance. Outside the blue band (Oklab hue -170 to -40
    // degrees, feather included) it keeps its Oklab hue; inside the band proper
    // (-150 to -60) it keeps its dominant wavelength, a straight line through
    // neutral.
    const auto hue_of = [](const std::array<float, 3>& rgb) {
      const auto v = linear_p3_to_oklab(rgb[0], rgb[1], rgb[2]);
      return std::atan2(v[2], v[1]);
    };
    const auto chroma_of = [](const std::array<float, 3>& rgb) {
      const auto v = linear_p3_to_oklab(rgb[0], rgb[1], rgb[2]);
      return std::hypot(v[1], v[2]);
    };
    const auto degrees = [](float radians) { return radians * 180.0F / 3.14159265F; };
    const auto inside_fit = fit_linear_p3_gamut(0.3F, 0.6F, 0.1F, 1.0F);
    require(inside_fit == std::array<float, 3>{0.3F, 0.6F, 0.1F},
            "gamut fitting changed a colour already inside");
    const auto rec2020_green = rec2020_to_linear_p3(0.0F, 1.0F, 0.0F);
    require(fit_linear_p3_to_gamut(rec2020_green[0], rec2020_green[1],
                rec2020_green[2], 1.0F, ColorGamut::kRec2020) == rec2020_green,
            "Rec.2020 matrix rounding must not compress a pure target primary");
    const auto outside_2020 = rec2020_to_linear_p3(-0.01F, 0.8F, 0.0F);
    const auto fitted_2020 = fit_linear_p3_to_gamut(outside_2020[0],
        outside_2020[1], outside_2020[2], 1.0F, ColorGamut::kRec2020);
    const auto target_2020 = p3_to_rec2020(fitted_2020[0], fitted_2020[1],
        fitted_2020[2]);
    for (float value : target_2020)
      require(value >= -2.0e-6F && value <= 1.0F + 2.0e-6F,
              "Rec.2020 fit left the target cube");
    int oklab_cases = 0;
    int straight_cases = 0;
    for (const bool rec709 : {false, true}) {
      for (const auto& colour : {std::array<float, 3>{1.6F, 0.1F, 0.05F},
                                 std::array<float, 3>{-0.08F, 0.7F, 0.9F},
                                 std::array<float, 3>{0.1F, 0.2F, 2.5F},
                                 std::array<float, 3>{-0.04F, -0.01F, 0.58F},
                                 std::array<float, 3>{0.95F, 0.9F, -0.05F},
                                 std::array<float, 3>{0.0F, 1.0F, 0.0F},
                                 std::array<float, 3>{1.2F, -0.05F, 0.9F}}) {
        for (const float limit : {1.0F, 4.0F}) {
          const auto out = fit_linear_p3_gamut(colour[0], colour[1], colour[2], limit, rec709);
          const auto check = rec709 ? linear_p3_to_rec709(out[0], out[1], out[2]) : out;
          for (const float value : check) {
            require(value >= -1.0e-5F && value <= limit + 1.0e-5F,
                    "gamut fitting left the target cube");
          }
          const float wanted = std::clamp(
              0.2289746F * colour[0] + 0.6917385F * colour[1] + 0.0792869F * colour[2], 0.0F, limit);
          require(std::abs(p3_luminance(out[0], out[1], out[2]) - wanted) < 2.0e-5F * std::max(1.0F, wanted),
                  "gamut fitting changed luminance");
          if (out == colour || !(chroma_of(out) > 1.0e-3F)) continue;
          const float hue = degrees(hue_of(colour));
          if (hue < -170.0F || hue > -40.0F) {
            const float turn = std::remainder(hue_of(out) - hue_of(colour), 6.2831853F);
            require(std::abs(turn) < 2.0e-3F, "gamut fitting turned the Oklab hue");
            ++oklab_cases;
          } else if (hue > -150.0F && hue < -60.0F) {
            // (out - Y) is a non-negative multiple of (colour - Y).
            std::array<float, 3> along{};
            std::array<float, 3> fitted{};
            for (std::size_t c = 0; c < 3; ++c) {
              along[c] = colour[c] - wanted;
              fitted[c] = out[c] - wanted;
            }
            const float cross = std::hypot(
                std::hypot(along[1] * fitted[2] - along[2] * fitted[1],
                           along[2] * fitted[0] - along[0] * fitted[2]),
                along[0] * fitted[1] - along[1] * fitted[0]);
            const float dot = along[0] * fitted[0] + along[1] * fitted[1] + along[2] * fitted[2];
            require(cross < 1.0e-4F * std::hypot(std::hypot(along[0], along[1]), along[2]) &&
                        dot >= 0.0F,
                    "gamut fitting of a blue left its dominant wavelength");
            ++straight_cases;
          }
        }
      }
    }
    require(oklab_cases > 0 && straight_cases > 0,
            "the gamut fitting cases no longer cover both hue paths");
    const auto too_bright = fit_linear_p3_gamut(3.0F, 3.0F, 0.0F, 1.0F);
    require(too_bright == std::array<float, 3>{1.0F, 1.0F, 1.0F},
            "a colour brighter than the limit did not fit to neutral at the limit");
    // Along a saturation ramp at fixed Oklab hue and luminance, fitted chroma
    // never falls while the input's rises (checked where the Oklab path holds).
    for (int turn = 0; turn < 36; ++turn) {
      const float angle = 6.2831853F * static_cast<float>(turn) / 36.0F;
      const float angle_degrees = std::remainder(degrees(angle), 360.0F);
      if (angle_degrees >= -170.0F && angle_degrees <= -40.0F) continue;
      float previous_chroma = 0.0F;
      for (int step = 0; step <= 200; ++step) {
        const float c = 0.4F * static_cast<float>(step) / 200.0F;
        auto rgb = oklab_to_linear_p3(0.8F, c * std::cos(angle), c * std::sin(angle));
        const float y = p3_luminance(rgb[0], rgb[1], rgb[2]);
        if (!(y > 1.0e-4F)) continue;
        for (auto& channel : rgb) channel *= 0.5F / y;
        const auto out = fit_linear_p3_gamut(rgb[0], rgb[1], rgb[2], 1.0F, true);
        const float chroma = chroma_of(out);
        require(chroma >= previous_chroma - 1.0e-4F,
                "fitted chroma fell while the input's rose");
        previous_chroma = chroma;
      }
    }

    const auto compressed_red = compress_linear_p3_to_srgb(1.0F, 0.0F, 0.0F);
    require(std::abs(std::remainder(hue_of(compressed_red) - hue_of({1.0F, 0.0F, 0.0F}),
                                    6.2831853F)) < 2.0e-3F,
            "sRGB gamut compression turned P3 red's hue");
    const auto compressed_red_srgb = linear_p3_to_rec709(
        compressed_red[0], compressed_red[1], compressed_red[2]);
    for (const float value : compressed_red_srgb) {
      require(value >= -1.0e-5F && value <= 1.0F + 1.0e-5F,
              "sRGB gamut compression left the SDR cube");
    }
    const auto neutral = compress_linear_p3_to_srgb(0.4F, 0.4F, 0.4F);
    require(std::abs(neutral[0] - neutral[1]) < 1.0e-5F &&
                std::abs(neutral[1] - neutral[2]) < 1.0e-5F,
            "sRGB gamut compression changed neutral colour");
    const auto hdr_red = compress_linear_p3_to_srgb(2.0F, 0.0F, 0.0F, true);
    const auto hdr_red_srgb = linear_p3_to_rec709(
        hdr_red[0], hdr_red[1], hdr_red[2]);
    require(std::max({hdr_red_srgb[0], hdr_red_srgb[1], hdr_red_srgb[2]}) > 1.0F,
            "HDR gamut compression discarded headroom");

    const auto green2020 = rec2020_to_linear_p3(0.0F, 1.0F, 0.0F);
    require(green2020[1] > 0.0F, "Rec.2020 green lost luminance converting to P3");

    // Dither must be deterministic and stay in range.
    require(quantize_dithered(0.321F, 255, 5, 9, 1) ==
                quantize_dithered(0.321F, 255, 5, 9, 1),
            "dithered quantization is not deterministic");
    for (int i = 0; i < 2000; ++i) {
      const int q = quantize_dithered(static_cast<float>(i) / 1999.0F, 255,
                                      static_cast<std::uint32_t>(i),
                                      static_cast<std::uint32_t>(2 * i),
                                      static_cast<std::uint32_t>(i % 3));
      require(q >= 0 && q <= 255, "dithered code left [0, max]");
    }

    // TPDF dither has zero mean, so the average code tracks the undithered value.
    for (const float v : {0.0F, 0.25F, 0.5F, 0.753F, 1.0F}) {
      double sum = 0.0;
      int count = 0;
      for (std::uint32_t y = 0; y < 128; ++y) {
        for (std::uint32_t x = 0; x < 128; ++x) {
          sum += quantize_dithered(v, 1023, x, y, 0);
          ++count;
        }
      }
      const double mean = sum / count;
      require(std::abs(mean - static_cast<double>(v) * 1023.0) < 2.0,
              "dither mean drifted from the undithered value");
    }

    std::cout << "color/dither tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "color/dither test failure: " << error.what() << '\n';
    return 1;
  }
}
