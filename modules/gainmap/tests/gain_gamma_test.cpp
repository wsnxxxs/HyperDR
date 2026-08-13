#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/gainmap/gain_map.hpp"

#include <cmath>
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
    error += weight * (decoded - q) * (decoded - q);
  }
  return error;
}

}  // namespace

int main() {
  try {
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
