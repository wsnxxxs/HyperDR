#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/gain_map.hpp"

#include <algorithm>
#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

float decoded_gain(const hyperdr::GainMapResult& result, std::uint32_t x, std::uint32_t y) {
  return hyperdr::rational_value(result.metadata.gain_max) *
      hyperdr::decode_gain_code(result.gain_map.at(x, y, 0), hyperdr::rational_value(result.metadata.gamma));
}

float decoded_bilinear_gain(const hyperdr::GainMapResult& result,
                             std::uint32_t source_width, std::uint32_t source_height,
                             std::uint32_t x, std::uint32_t y) {
  const float gx = std::clamp((static_cast<float>(x) + 0.5F) * result.gain_map.width / source_width -
                                  0.5F,
                              0.0F, static_cast<float>(result.gain_map.width - 1));
  const float gy = std::clamp((static_cast<float>(y) + 0.5F) * result.gain_map.height / source_height -
                                  0.5F,
                              0.0F, static_cast<float>(result.gain_map.height - 1));
  const auto x0 = static_cast<std::uint32_t>(std::floor(gx));
  const auto y0 = static_cast<std::uint32_t>(std::floor(gy));
  const auto x1 = std::min(x0 + 1U, result.gain_map.width - 1U);
  const auto y1 = std::min(y0 + 1U, result.gain_map.height - 1U);
  const float top = std::lerp(result.gain_map.at(x0, y0, 0), result.gain_map.at(x1, y0, 0), gx - x0);
  const float bottom = std::lerp(result.gain_map.at(x0, y1, 0), result.gain_map.at(x1, y1, 0), gx - x0);
  const float code = std::lerp(top, bottom, gy - y0);
  return hyperdr::rational_value(result.metadata.gain_max) *
      hyperdr::decode_gain_code(code, hyperdr::rational_value(result.metadata.gamma));
}

}  // namespace

int main() {
  try {
    hyperdr::FloatImage source(192, 128, 3);
    for (std::uint32_t y = 0; y < source.height; ++y) {
      for (std::uint32_t x = 0; x < source.width; ++x) {
        float value = x < 112 ? 1.2F : 0.015F;
        if (x >= 148 && x <= 154 && y >= 60 && y <= 66) value = 18.0F;
        source.at(x, y, 0) = value;
        source.at(x, y, 1) = value;
        source.at(x, y, 2) = value;
      }
    }
    hyperdr::GainMapOptions options;
    options.auto_exposure = false;
    options.auto_headroom = false;
    options.headroom_stops = 3.0F;
    hyperdr::CaptureMetadata capture;
    capture.iso = 100.0F;
    const auto result = hyperdr::make_gain_map(source, options, capture);
    const auto wall_x = result.gain_map.width * 24U / source.width;
    const auto bulb_x = result.gain_map.width * 151U / source.width;
    const auto bulb_y = result.gain_map.height * 63U / source.height;
    const float wall_gain = decoded_gain(result, wall_x, bulb_y);
    const float bulb_gain = decoded_gain(result, bulb_x, bulb_y);
    require(bulb_gain > wall_gain + 0.15F,
            "small bright light did not receive more local gain than a white wall");
    const auto black_x = result.gain_map.width * 180U / source.width;
    require(decoded_gain(result, black_x, 0) < 1.0e-6F,
            "guided filter leaked gain into a black region");
    for (const float code : result.gain_map.pixels) {
      require(std::isfinite(code) && code >= 0.0F && code <= 1.0F,
              "local gain encoding left the valid range");
    }
    require(result.stats.local_weight_mean >= 0.0F && result.stats.local_weight_mean <= 1.0F &&
                result.stats.local_weight_p95 >= 0.0F && result.stats.local_weight_p95 <= 1.0F,
            "local-gain weight statistics are outside their valid range");

    // A bright block and surrounding dark pixels share downsampled gain-grid
    // support. A narrow edge transition is intentional, while the far dark field
    // must remain protected from guided-filter gain spill.
    hyperdr::FloatImage mixed(64, 64, 3);
    for (std::uint32_t y = 0; y < mixed.height; ++y) {
      for (std::uint32_t x = 0; x < mixed.width; ++x) {
        const float value = x >= 27 && x < 37 && y >= 27 && y < 37 ? 12.0F : 0.01F;
        mixed.at(x, y, 0) = value;
        mixed.at(x, y, 1) = value;
        mixed.at(x, y, 2) = value;
      }
    }
    const auto mixed_result = hyperdr::make_gain_map(mixed, options, capture);
    float mixed_max_gain = 0.0F;
    float far_dark_max_gain = 0.0F;
    for (std::uint32_t y = 0; y < mixed.height; ++y) {
      for (std::uint32_t x = 0; x < mixed.width; ++x) {
        const float decoded = decoded_bilinear_gain(mixed_result, mixed.width, mixed.height, x, y);
        mixed_max_gain = std::max(mixed_max_gain, decoded);
        const bool far_from_highlight = x < 24 || x >= 40 || y < 24 || y >= 40;
        if (mixed.at(x, y, 0) < 0.02F && far_from_highlight) {
          far_dark_max_gain = std::max(far_dark_max_gain, decoded);
        }
      }
    }
    require(mixed_max_gain > 0.05F, "mixed bright block lost all HDR gain");
    require(far_dark_max_gain < 0.05F, "soft gain support leaked into the far dark field");
    std::cout << "local gain tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "local gain test failure: " << error.what() << '\n';
    return 1;
  }
}
