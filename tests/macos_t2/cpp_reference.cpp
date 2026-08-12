#include "hyperdr/gainmap/reconstruct.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

std::uint32_t read_u32(std::istream& stream) {
  std::uint8_t bytes[4]{};
  stream.read(reinterpret_cast<char*>(bytes), 4);
  if (!stream) throw std::runtime_error("truncated T2 input header");
  return static_cast<std::uint32_t>(bytes[0]) |
         (static_cast<std::uint32_t>(bytes[1]) << 8U) |
         (static_cast<std::uint32_t>(bytes[2]) << 16U) |
         (static_cast<std::uint32_t>(bytes[3]) << 24U);
}

float read_float(std::istream& stream) {
  return std::bit_cast<float>(read_u32(stream));
}

hyperdr::FloatImage read_image(std::istream& stream, std::uint32_t width,
                               std::uint32_t height, std::uint32_t channels) {
  hyperdr::FloatImage image(width, height, channels);
  for (float& value : image.pixels) {
    value = read_float(stream);
    if (!std::isfinite(value)) throw std::runtime_error("non-finite T2 input pixel");
  }
  return image;
}

struct Inputs {
  hyperdr::FloatImage base;
  hyperdr::FloatImage gain;
};

Inputs read_inputs(const std::string& path) {
  std::ifstream stream(path, std::ios::binary);
  if (!stream) throw std::runtime_error("cannot open T2 input bundle");
  char magic[8]{};
  stream.read(magic, 8);
  if (!stream || std::string(magic, 8) != "HDT2IN01") {
    throw std::runtime_error("invalid T2 input magic");
  }
  const auto base_width = read_u32(stream);
  const auto base_height = read_u32(stream);
  const auto gain_width = read_u32(stream);
  const auto gain_height = read_u32(stream);
  auto base = read_image(stream, base_width, base_height, 3);
  auto gain = read_image(stream, gain_width, gain_height, 1);
  char extra{};
  if (stream.read(&extra, 1)) throw std::runtime_error("trailing T2 input bytes");
  return {std::move(base), std::move(gain)};
}

hyperdr::FloatImage decoded_domain_first(
    const hyperdr::FloatImage& base, const hyperdr::FloatImage& gain,
    const hyperdr::GainMapMetadata& metadata, float display_headroom_stops) {
  hyperdr::FloatImage output(base.width, base.height, 3);
  const float base_headroom = hyperdr::rational_value(metadata.base_headroom);
  const float alternate_headroom =
      hyperdr::rational_value(metadata.alternate_headroom);
  const float denominator = alternate_headroom - base_headroom;
  const float fraction = std::abs(denominator) < 1.0e-8F
                             ? 0.0F
                             : std::clamp((display_headroom_stops - base_headroom) /
                                              denominator,
                                          0.0F, 1.0F);
  const float weight = std::copysign(fraction, denominator);
  const float gamma =
      std::max(hyperdr::rational_value(metadata.gamma), 1.0e-6F);
  const float gain_min = hyperdr::rational_value(metadata.gain_min);
  const float gain_max = hyperdr::rational_value(metadata.gain_max);
  const float base_offset = hyperdr::rational_value(metadata.base_offset);
  const float alternate_offset =
      hyperdr::rational_value(metadata.alternate_offset);
  for (std::uint32_t y = 0; y < base.height; ++y) {
    const float gy = std::clamp(
        (static_cast<float>(y) + 0.5F) * gain.height / base.height - 0.5F,
        0.0F, static_cast<float>(gain.height - 1));
    const auto y0 = static_cast<std::uint32_t>(std::floor(gy));
    const auto y1 = std::min(y0 + 1, gain.height - 1);
    const float wy = gy - static_cast<float>(y0);
    for (std::uint32_t x = 0; x < base.width; ++x) {
      const float gx = std::clamp(
          (static_cast<float>(x) + 0.5F) * gain.width / base.width - 0.5F,
          0.0F, static_cast<float>(gain.width - 1));
      const auto x0 = static_cast<std::uint32_t>(std::floor(gx));
      const auto x1 = std::min(x0 + 1, gain.width - 1);
      const float wx = gx - static_cast<float>(x0);
      const auto decode = [gamma](float code) {
        return std::pow(std::clamp(code, 0.0F, 1.0F), 1.0F / gamma);
      };
      const float top = std::lerp(decode(gain.at(x0, y0, 0)),
                                  decode(gain.at(x1, y0, 0)), wx);
      const float bottom = std::lerp(decode(gain.at(x0, y1, 0)),
                                     decode(gain.at(x1, y1, 0)), wx);
      const float decoded = std::clamp(std::lerp(top, bottom, wy), 0.0F, 1.0F);
      const float log_gain = std::lerp(gain_min, gain_max, decoded);
      for (unsigned channel = 0; channel < 3; ++channel) {
        output.at(x, y, channel) =
            std::max(0.0F, (base.at(x, y, channel) + base_offset) *
                                   std::exp2(log_gain * weight) -
                               alternate_offset);
      }
    }
  }
  return output;
}

void write_pixels(std::ostream& stream, const std::vector<float>& pixels) {
  stream << '[';
  for (std::size_t index = 0; index < pixels.size(); ++index) {
    if (index) stream << ',';
    stream << pixels[index];
  }
  stream << ']';
}

float parse_float(const char* text, const char* name) {
  std::size_t used = 0;
  const float value = std::stof(text, &used);
  if (text[used] != '\0' || !std::isfinite(value)) {
    throw std::invalid_argument(std::string("invalid ") + name);
  }
  return value;
}

}  // namespace

int main(int argc, char** argv) {
  try {
    if (argc != 8) {
      throw std::invalid_argument(
          "usage: t2_reference <input.bin> <output.json> <gamma> "
          "<headroom-stops-1> <headroom-stops-2> <headroom-stops-3> "
          "<fixture-id>");
    }
    const auto inputs = read_inputs(argv[1]);
    const float gamma = parse_float(argv[3], "gamma");
    const std::vector<float> headrooms{parse_float(argv[4], "headroom"),
                                       parse_float(argv[5], "headroom"),
                                       parse_float(argv[6], "headroom")};
    if ((gamma != 1.0F && gamma != 2.0F) || !(headrooms[0] > 0.0F) ||
        !(headrooms[1] > headrooms[0]) || !(headrooms[2] > headrooms[1]) ||
        !(headrooms[2] < 2.0F)) {
      throw std::invalid_argument("T2 gamma/headrooms violate the frozen contract");
    }
    hyperdr::GainMapMetadata metadata;
    metadata.gain_min = {0, 1};
    metadata.gain_max = {2, 1};
    metadata.gamma = {static_cast<std::int32_t>(gamma), 1};
    metadata.base_offset = {0, 1};
    metadata.alternate_offset = {0, 1};
    metadata.base_headroom = {0, 1};
    metadata.alternate_headroom = {2, 1};

    std::ofstream output(argv[2], std::ios::binary | std::ios::trunc);
    if (!output) throw std::runtime_error("cannot open T2 C++ report output");
    output << std::setprecision(std::numeric_limits<float>::max_digits10);
    output << "{\"schema_version\":1,\"fixture_id\":\"" << argv[7]
           << "\",\"implementation\":\"modules/gainmap/src/reconstruct.cpp::"
              "reconstruct_gain_map\",\"width\":"
           << inputs.base.width << ",\"height\":" << inputs.base.height
           << ",\"channels\":3,\"gamma\":" << gamma << ",\"nodes\":[";
    for (std::size_t index = 0; index < headrooms.size(); ++index) {
      if (index) output << ',';
      const auto code_domain = hyperdr::reconstruct_gain_map(
          inputs.base, inputs.gain, metadata, headrooms[index]);
      const auto decoded_domain = decoded_domain_first(
          inputs.base, inputs.gain, metadata, headrooms[index]);
      output << "{\"physical_headroom_stops\":" << headrooms[index]
             << ",\"code_domain_rgb\":";
      write_pixels(output, code_domain.pixels);
      output << ",\"decoded_domain_first_rgb\":";
      write_pixels(output, decoded_domain.pixels);
      output << '}';
    }
    output << "]}\n";
    if (!output) throw std::runtime_error("failed writing T2 C++ report");
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "macOS T2 C++ reference failure: " << error.what() << '\n';
    return 1;
  }
}
