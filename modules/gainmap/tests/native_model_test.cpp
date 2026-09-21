#include "hyperdr/gainmap/native_model.hpp"
#include "hyperdr/gainmap/research_exif_level.hpp"

#include "hyperdr/foundation/rational.hpp"

#include <array>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

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

// The table is the whole of what can be selected, so both halves are asserted:
// every advertised option resolves, and an id that is not in it is refused
// rather than quietly becoming the incumbent.
void test_model_ids_are_a_closed_set() {
  require(hyperdr::normalize_native_model_id("") == "research-cnn-v1" &&
              hyperdr::normalize_native_model_id("embedded") == "research-cnn-v1" &&
              hyperdr::normalize_native_model_id("research-cnn-v1") == "research-cnn-v1" &&
              hyperdr::normalize_native_model_id("research-exif-v1") == "research-exif-v1",
          "a known or legacy model id did not resolve to its canonical form");

  bool rejected = false;
  try {
    (void)hyperdr::normalize_native_model_id("production-v3");
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "an unknown model id was accepted");

  const auto& table = hyperdr::native_model_table();
  require(table.size() == 2, "the model table does not hold the two options");
  for (const auto& descriptor : table) {
    require(hyperdr::native_model_id_known(descriptor.id) &&
                !descriptor.display_name.empty() &&
                !descriptor.display_key.empty() && !descriptor.version.empty(),
            "a table entry is not fully described");
    if (!descriptor.fallback_id.empty()) {
      require(hyperdr::native_model_id_known(descriptor.fallback_id),
              "a model falls back to an id that is not in the table");
    }
    if (descriptor.fallback_id.empty()) {
      require(!descriptor.requires_capture,
              "a model needs capture settings but can never fall back");
    }
  }
}

// The offsets follow the model that answered, not the one that was asked for:
// a fallback from model 2 to model 1 must reconstruct with model 1's convention,
// or the picture would be a blend of two different curves.
void test_reconstruction_offsets_follow_the_effective_model() {
  const auto research = hyperdr::make_native_model_output(
      "research-exif-v1", "research-cnn-v1", hyperdr::kInferenceModeFallback,
      "missing_capture_fields:iso", hyperdr::FloatImage(2, 1, 1));
  require(research.requested_model_id == "research-exif-v1" &&
              research.effective_model_id == "research-cnn-v1" &&
              research.inference_mode == "pixel_only_fallback" &&
              research.fallback_reason == "missing_capture_fields:iso",
          "a fallback lost the identity of what actually ran");
  require(research.base_offset.numerator == 1 && research.base_offset.denominator == 100000 &&
              research.alternate_offset.numerator == 1,
          "a research prediction did not carry the 1e-5 reconstruction offset");

  // The 1e-5 offsets are asserted as the base offset, which is the field the
  // encoder writes and the reconstruction adds back. An offset that only reached
  // the report would render the incumbent's curve under the 1e-5 label.
  auto input = neutral_input();
  auto result = empty_result();
  auto prediction = hyperdr::make_native_model_output(
      "research-cnn-v1", "research-cnn-v1", hyperdr::kInferenceModePixelOnly, {},
      hyperdr::FloatImage(2, 1, 1));
  prediction.signed_log2_gain.pixels = {0.5F, 0.5F};
  hyperdr::apply_native_model_gain_map(result, input, std::move(prediction));
  require(result.metadata.base_offset.numerator == 1 &&
              result.metadata.base_offset.denominator == 100000 &&
              result.metadata.alternate_offset.numerator == 1,
          "the research offset was dropped before the encoder saw it");


}

// Values from the fitted scikit-learn pipeline, read once and recorded here. The
// generated arrays are a copy of that object; this is the check that the copy
// was walked correctly, including the child-index convention that a mistake in
// would otherwise show up only as a slightly wrong picture.
void test_research_exif_level_matches_the_fitted_estimator() {
  const std::array<double, hyperdr::kCaptureParameterCount> medians{
      6.643856189774724, -6.643856189774724, 1.7799999713880652,
      0.0, 6.764999866370901, 30.0};
  const std::array<bool, hyperdr::kCaptureParameterCount> all_present{
      true, true, true, true, true, true};
  require(std::abs(hyperdr::research_exif_level(medians, all_present) -
                   0.73748320701771175) < 1.0e-9,
          "the all-median capture does not reproduce the fitted estimator");

  const std::array<double, hyperdr::kCaptureParameterCount> sony{
      8.643856189774724, -8.965784284662087, 2.8, 0.0, 35.0, 35.0};
  require(std::abs(hyperdr::research_exif_level(sony, all_present) -
                   0.79861616215399844) < 1.0e-9,
          "a complete capture does not reproduce the fitted estimator");

  const std::array<double, hyperdr::kCaptureParameterCount> high_iso{
      13.643856189774724, -5.906890595608519, 1.8, -0.67, 16.0, 24.0};
  require(std::abs(hyperdr::research_exif_level(high_iso, all_present) -
                   0.52667847741907825) < 1.0e-9,
          "a high-ISO capture does not reproduce the fitted estimator");

  // The same vector with every field absent must fall back to the medians, which
  // is what the imputer doing its job looks like from here.
  const std::array<double, hyperdr::kCaptureParameterCount> zeros{};
  const std::array<bool, hyperdr::kCaptureParameterCount> none{};
  require(std::abs(hyperdr::research_exif_level(zeros, none) -
                   hyperdr::research_exif_level(medians, all_present)) < 1.0e-12,
          "an absent capture was not imputed with the fitted medians");
}

// A clipped white is the brightest valid SDR sample, and area resampling of it
// must stay a valid model input. At a 1280x853 preview the float weights sum a
// rounding step above one, which used to push 1.0 to 1.0000001 and refused the
// AI preview for every photograph with clipped highlights at that size.
void test_model_input_tolerates_resample_rounding() {
  for (const auto [width, height] : {std::array<std::uint32_t, 2>{1280, 853},
                                     std::array<std::uint32_t, 2>{2048, 1365},
                                     std::array<std::uint32_t, 2>{1440, 959}}) {
    hyperdr::FloatImage white(width, height, 3);
    white.pixels.assign(white.pixels.size(), 1.0F);
    const auto tensor = hyperdr::make_native_model_input(white);
    require(tensor.width % 16U == 0 && tensor.height % 16U == 0,
            "model input lost its stride alignment");
    for (const float value : tensor.pixels) {
      require(value >= 0.0F && value <= 1.0F,
              "resampled model input left the [0, 1] contract");
    }
  }

  // The tolerance absorbs rounding, not a base that is genuinely out of range.
  hyperdr::FloatImage overexposed(1280, 853, 3);
  overexposed.pixels.assign(overexposed.pixels.size(), 1.5F);
  bool rejected = false;
  try {
    (void)hyperdr::make_native_model_input(overexposed);
  } catch (const std::invalid_argument&) {
    rejected = true;
  }
  require(rejected, "an out-of-range model base was silently clamped");
}

}  // namespace

int main() {
  try {
    test_identity_preserves_raw_signed_stops();
    test_constant_field_is_scaled_once();
    test_model_ids_are_a_closed_set();
    test_reconstruction_offsets_follow_the_effective_model();
    test_research_exif_level_matches_the_fitted_estimator();
    test_model_input_tolerates_resample_rounding();
    std::cout << "native model tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "test failure: " << error.what() << '\n';
    return 1;
  }
}
