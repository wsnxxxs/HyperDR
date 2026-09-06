#include "hyperdr/gainmap/native_model.hpp"

#include "hyperdr/foundation/rational.hpp"

#include <cmath>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

float decoded_stop(const hyperdr::GainMapResult& result, std::size_t index) {
  const float minimum = hyperdr::rational_value(result.metadata.gain_min);
  const float maximum = hyperdr::rational_value(result.metadata.gain_max);
  return minimum + result.gain_map.pixels[index] * (maximum - minimum);
}

hyperdr::FloatImage neutral_input() {
  hyperdr::FloatImage input(32, 16, 3);
  input.pixels.assign(input.pixels.size(), 0.5F);
  return input;
}

hyperdr::GainMapResult empty_result() {
  hyperdr::GainMapResult result;
  result.base_linear = hyperdr::FloatImage(4, 2, 3);
  result.base_linear.pixels.assign(result.base_linear.pixels.size(), 0.5F);
  return result;
}

void test_identity_preserves_raw_signed_stops() {
  auto input = neutral_input();
  auto result = empty_result();
  hyperdr::NativeModelOutput output{hyperdr::FloatImage(2, 1, 1)};
  output.signed_log2_gain.pixels = {-0.1234564F, 1.2345674F};

  hyperdr::apply_native_model_gain_map(result, input, std::move(output));

  require(result.gain_map.width == 2 && result.gain_map.height == 1,
          "identity model grid was unexpectedly resized twice");
  require(std::abs(decoded_stop(result, 0) + 0.1234564F) < 1.0e-6F &&
              std::abs(decoded_stop(result, 1) - 1.2345674F) < 1.0e-6F,
          "identity post-processing changed raw signed stops");
  require(result.metadata.gain_min.denominator == 1000000U &&
              result.metadata.gain_max.denominator == 1000000U &&
              hyperdr::rational_value(result.metadata.gain_min) <=
                  -0.1234564F &&
              hyperdr::rational_value(result.metadata.gain_max) >=
                  1.2345674F,
          "gain metadata does not outwardly enclose model samples");
}

void test_constant_field_is_scaled_once() {
  auto input = neutral_input();
  auto result = empty_result();
  hyperdr::NativeModelOutput output{hyperdr::FloatImage(2, 1, 1)};
  output.signed_log2_gain.pixels.assign(2, 0.75F);

  hyperdr::apply_native_model_gain_map(result, input, std::move(output), 0.5F);

  require(std::abs(decoded_stop(result, 0) - 0.375F) < 1.0e-6F &&
              std::abs(decoded_stop(result, 1) - 0.375F) < 1.0e-6F,
          "constant signed-stop field was filtered or scaled twice");
}

}  // namespace

int main() {
  try {
    test_identity_preserves_raw_signed_stops();
    test_constant_field_is_scaled_once();
    std::cout << "native model tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "test failure: " << error.what() << '\n';
    return 1;
  }
}
