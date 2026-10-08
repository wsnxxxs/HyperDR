#pragma once

#include "hyperdr/app/settings.hpp"

#include <algorithm>
#include <charconv>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace hyperdr::app::detail {

template <class T>
T integer(std::string_view text, const char* name) {
  T value{};
  const auto result = std::from_chars(text.data(), text.data() + text.size(), value);
  if (result.ec != std::errc{} || result.ptr != text.data() + text.size()) {
    throw std::invalid_argument(std::string("invalid ") + name);
  }
  return value;
}

struct PreviewRegion {
  std::optional<std::uint32_t> left, top, width, height;
  bool center{false};
  [[nodiscard]] bool requested() const {
    return left || top || width || height || center;
  }
  void resolve(std::uint32_t image_width, std::uint32_t image_height) {
    if (!width || !height || *width == 0 || *height == 0 ||
        *width > 2048 || *height > 2048 || image_width == 0 || image_height == 0 ||
        (!center && (!left || !top))) {
      throw std::invalid_argument("detail region must have a position and be at most 2048 pixels per side");
    }
    *width = std::min(*width, image_width);
    *height = std::min(*height, image_height);
    if (center) {
      left = (image_width - *width) / 2;
      top = (image_height - *height) / 2;
    } else {
      left = std::min(*left, image_width - *width);
      top = std::min(*top, image_height - *height);
    }
  }
};

float real(std::string_view text, const char* name);
std::string next_value(int& i, int argc, char** argv, std::string_view option);
void parse_settings(int argc, char** argv, int first, ConvertOptions& options,
                    unsigned* curve_samples = nullptr, PreviewRegion* region = nullptr);

int convert_command(int argc, char** argv);
int curve_command(int argc, char** argv);
int schema_command(int argc, char** argv);
int display_curve_command(int argc, char** argv);

int inspect_command(int argc, char** argv);
int verify_command(int argc, char** argv);
int thumbnail_command(int argc, char** argv);
int raw_metadata_command(int argc, char** argv);

void append_u32_le(std::vector<std::uint8_t>& bytes, std::uint32_t value);
void append_float_image(std::vector<std::uint8_t>& bytes, const FloatImage& image);
void set_stdout_binary();

int model_gain_command(int argc, char** argv);
int model_list_command(int argc, char** argv);
int model_input_command(int argc, char** argv);

}  // namespace hyperdr::app::detail
