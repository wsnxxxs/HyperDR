#include "hyperdr/gainmap/external.hpp"

#include "hyperdr/foundation/rational.hpp"

#include <bit>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void write_float_le(std::ofstream& output, float value) {
  const auto bits = std::bit_cast<std::uint32_t>(value);
  const char bytes[4]{
      static_cast<char>(bits & 0xffU),
      static_cast<char>((bits >> 8U) & 0xffU),
      static_cast<char>((bits >> 16U) & 0xffU),
      static_cast<char>((bits >> 24U) & 0xffU),
  };
  output.write(bytes, sizeof(bytes));
}

void test_external_gain_round_trip() {
  const auto root = std::filesystem::temp_directory_path() /
                    "hyperdr-external-gain-test";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);
  const auto raw = root / "gain.f32";
  const auto report = root / "gain.json";
  {
    std::ofstream output(raw, std::ios::binary);
    write_float_le(output, 0.0F);
    write_float_le(output, 0.5F);
    write_float_le(output, 1.0F);
    write_float_le(output, 0.25F);
  }
  {
    std::ofstream output(report);
    output << R"({
  "gain_grid_size": [2, 2],
  "metadata_gain_max_stops": 3.0,
  "gain_file": {
    "format": "raw_float32_with_required_json_sidecar",
    "endianness": "little",
    "scale": "normalized_log2_gain_0_to_1",
    "width": 2,
    "height": 2,
    "byte_length": 16
  }
})";
  }

  auto external = hyperdr::read_external_gain_map(raw, report, true);
  require(external.gain_map.width == 2 && external.gain_map.height == 2,
          "external dimensions were not read");
  require(external.gain_map.pixels[2] == 1.0F,
          "little-endian float was not decoded");
  require(external.max_stops == 3.0F, "external headroom was not read");

  hyperdr::GainMapResult result;
  result.base_linear = hyperdr::FloatImage(4, 4, 3);
  hyperdr::apply_external_gain_map(result, std::move(external));
  require(hyperdr::rational_value(result.metadata.gain_max) == 3.0F,
          "external gain metadata was not applied");
  require(result.headroom_stops == 3.0F,
          "external headroom was not applied");
  require(result.stats.gain_percentiles[7] == 3.0F,
          "external gain statistics were not applied");

  hyperdr::FloatImage source(2, 1, 3);
  source.pixels = {0.2F, 0.4F, 0.6F, 1.4F, -0.2F, 0.8F};
  hyperdr::ExternalGainMap pure_external{
      hyperdr::FloatImage(1, 1, 1), 3.0F};
  pure_external.gain_map.pixels[0] = 0.5F;
  const auto pure =
      hyperdr::make_external_gain_map(source, std::move(pure_external));
  require(pure.exposure_ev == 0.0F,
          "pure external mode applied exposure");
  require(pure.base_linear.pixels[0] == 0.2F &&
              pure.base_linear.pixels[1] == 0.4F &&
              pure.base_linear.pixels[2] == 0.6F,
          "pure external mode changed legal source pixels");
  require(pure.base_linear.pixels[3] == 1.0F &&
              pure.base_linear.pixels[4] == 0.0F,
          "pure external mode did not clamp the SDR base");
  require(pure.gain_map.pixels[0] == 0.5F,
          "pure external mode changed the model gain");

  hyperdr::ExternalGainMap exposed_external{
      hyperdr::FloatImage(1, 1, 1), 3.0F};
  exposed_external.gain_map.pixels[0] = 0.5F;
  const auto exposed = hyperdr::make_external_gain_map(
      source, std::move(exposed_external), 1.0F, 1.0F);
  require(exposed.exposure_ev == 1.0F &&
              exposed.stats.exposure_ev == 1.0F,
          "external exposure anchor was not reported");
  require(exposed.base_linear.pixels[0] == 0.4F &&
              exposed.base_linear.pixels[1] == 0.8F &&
              exposed.base_linear.pixels[2] == 1.0F,
          "external exposure anchor was not applied before clamping");

  hyperdr::ExternalGainMap half_external{
      hyperdr::FloatImage(1, 1, 1), 3.0F};
  half_external.gain_map.pixels[0] = 0.5F;
  const auto half =
      hyperdr::make_external_gain_map(source, std::move(half_external), 0.5F);
  require(hyperdr::rational_value(half.metadata.gain_max) == 1.5F &&
              half.stats.gain_percentiles[7] == 0.75F,
          "external strength did not scale model gain stops");
  std::filesystem::remove_all(root);
}

void test_v2_signed_canonical_sidecar() {
  const auto root = std::filesystem::temp_directory_path() /
                    "hyperdr-external-gain-v2-test";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);
  const auto raw = root / "gain.f32";
  const auto report = root / "gain.json";
  {
    std::ofstream output(raw, std::ios::binary);
    write_float_le(output, -0.5F);
    write_float_le(output, 0.25F);
  }
  {
    std::ofstream output(report);
    output << R"({
  "label_contract_id": "hyperdr.apple-gain-label/v2",
  "gain_grid_size": [2, 1],
  "gain_file": {
    "format": "raw_float32_with_required_json_sidecar",
    "endianness": "little",
    "scale": "signed_log2_gain",
    "width": 2,
    "height": 1,
    "byte_length": 8
  },
  "gain_metadata": {
    "minimum_version": 0,
    "writer_version": 0,
    "flags": 64,
    "use_base_color_space": true,
    "backward_direction": false,
    "common_denominator": false,
    "base_headroom": {"numerator": 0, "denominator": 1000000},
    "alternate_headroom": {"numerator": 2000000, "denominator": 1000000},
    "gain_min": {"numerator": -1000000, "denominator": 1000000},
    "gain_max": {"numerator": 2000000, "denominator": 1000000},
    "gamma": {"numerator": 1000000, "denominator": 1000000},
    "base_offset": {"numerator": 0, "denominator": 1000000},
    "alternate_offset": {"numerator": 0, "denominator": 1000000}
  }
})";
  }
  const auto external = hyperdr::read_external_gain_map(raw, report, false);
  require(external.canonical_log2, "v2 sidecar was not recognized");
  require(external.gain_map.pixels[0] == -0.5F,
          "signed canonical gain was not preserved");
  hyperdr::GainMapResult result;
  hyperdr::apply_external_gain_map(result, std::move(external));
  require(hyperdr::rational_value(result.metadata.gain_min) == -1.0F,
          "v2 gain_min metadata was not applied");
  require(result.gain_map.pixels[0] > 0.0F && result.gain_map.pixels[1] > result.gain_map.pixels[0],
          "v2 canonical gain was not quantized to ISO code space");
  std::filesystem::remove_all(root);
}

}  // namespace

int main() {
  try {
    test_external_gain_round_trip();
    test_v2_signed_canonical_sidecar();
    std::cout << "external gain tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "test failure: " << error.what() << '\n';
    return 1;
  }
}
