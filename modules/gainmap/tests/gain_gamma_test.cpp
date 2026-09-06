#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/gain_map.hpp"

#include <cmath>
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

double quantized_error(const std::vector<float>& values, float gamma) {
  double error = 0.0;
  for (const float q : values) {
    const float code = std::round(255.0F * hyperdr::encode_gain_code(q, gamma)) / 255.0F;
    const float decoded = hyperdr::decode_gain_code(code, gamma);
    const float weight = 1.0F + 0.15F / (q + 0.05F);
    error += static_cast<double>(weight) * (decoded - q) * (decoded - q);
  }
  return error;
}

}  // namespace

int main() {
  try {
    hyperdr::FloatImage grid(257, 3, 1);
    for (std::size_t i = 0; i < grid.pixels.size(); ++i)
      grid.pixels[i] = static_cast<float>((i * 37) % 256) / 255.0F;
    for (float gamma : {0.4F, 1.0F, 2.0F}) {
      hyperdr::RenderStats stats;
      hyperdr::measure_quantized_gain(stats, grid, 3.0F, gamma, 3.0F);
      std::vector<float> decoded;
      std::size_t over_one = 0;
      for (float code : grid.pixels) {
        const float value = 3.0F * hyperdr::decode_gain_code(code, gamma);
        decoded.push_back(value);
        if (value > 1.0F) ++over_one;
      }
      std::sort(decoded.begin(), decoded.end());
      constexpr std::array<float, 8> fractions{0.5F, 0.75F, 0.9F, 0.95F, 0.99F, 0.999F, 0.9999F, 1.0F};
      for (std::size_t i = 0; i < fractions.size(); ++i)
        require(stats.gain_percentiles[i] == decoded[static_cast<std::size_t>(fractions[i] * (decoded.size() - 1))],
                "gain histogram differs from sorted decoded percentiles");
      require(stats.gain_fraction_gt_1_0 == static_cast<float>(over_one) / decoded.size(),
              "gain histogram changed the threshold fraction");
    }
    for (const float gamma : {0.40F, 0.75F, 1.0F, 1.50F, 2.0F}) {
      for (const float q : {0.0F, 0.01F, 0.10F, 0.50F, 1.0F}) {
        const float decoded = hyperdr::decode_gain_code(hyperdr::encode_gain_code(q, gamma), gamma);
        require(std::abs(decoded - q) < 1.0e-6F, "gain gamma round trip failed");
      }
    }
    require(hyperdr::encode_gain_code(0.04F, 0.50F) >
                hyperdr::encode_gain_code(0.04F, 1.0F),
            "gamma below one did not expand the low-gain code range");

    require(hyperdr::quantize_gain_code_dithered(0.0F, 7, 3) == 0.0F &&
                hyperdr::quantize_gain_code_dithered(0.49F / 255.0F, 7, 3) == 0.0F &&
                hyperdr::quantize_gain_code_dithered(1.0F, 7, 3) == 1.0F,
            "dithered gain quantization did not preserve endpoints");
    const float midpoint =
        hyperdr::quantize_gain_code_dithered(0.5F, 7, 3);
    bool saw_different_position_code = false;
    for (std::uint32_t x = 0; x < 64; ++x) {
      if (hyperdr::quantize_gain_code_dithered(0.5F, x, 3) != midpoint) {
        saw_different_position_code = true;
        break;
      }
    }
    require(saw_different_position_code,
            "dithered gain quantization did not decorrelate positions");
    for (const float code : {0.001F, 0.25F, 0.5F, 0.75F, 0.999F}) {
      const float quantized =
          hyperdr::quantize_gain_code_dithered(code, 7, 3);
      require(quantized >= 0.0F && quantized <= 1.0F &&
                  std::abs(quantized * 255.0F -
                           std::round(quantized * 255.0F)) < 1.0e-6F,
              "dithered gain quantization left 8-bit code space");
    }

    std::vector<float> values;
    for (int i = 0; i < 2000; ++i) values.push_back(static_cast<float>(i) / 1999.0F);
    const float adaptive = hyperdr::choose_gain_gamma(values);
    float reference_gamma = 1.0F;
    double reference_error = quantized_error(values, reference_gamma);
    for (float gamma : {0.40F, 0.50F, 0.60F, 0.75F, 0.90F, 1.00F, 1.20F, 1.50F, 2.00F}) {
      const auto error = quantized_error(values, gamma);
      if (error < reference_error) { reference_error = error; reference_gamma = gamma; }
    }
    if (quantized_error(values, 1.0F) <= reference_error * 1.01 + 1.0e-12) reference_gamma = 1.0F;
    require(adaptive == reference_gamma, "gamma lookup differs from direct power evaluation");
    require(quantized_error(values, adaptive) <= quantized_error(values, 1.0F) + 1.0e-10,
            "adaptive gamma is worse than gamma one");
    require(hyperdr::encode_gain_code(0.0F, adaptive) == 0.0F &&
                hyperdr::encode_gain_code(1.0F, adaptive) == 1.0F,
            "gain gamma did not preserve endpoints");
    std::cout << "gain gamma tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "gain gamma test failure: " << error.what() << '\n';
    return 1;
  }
}
