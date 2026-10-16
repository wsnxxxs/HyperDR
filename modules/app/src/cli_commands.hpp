#pragma once

#include "hyperdr/app/settings.hpp"
#include "hyperdr/app/engine.hpp"

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


float real(std::string_view text, const char* name);
std::string next_value(int& i, int argc, char** argv, std::string_view option);
void parse_settings(int argc, char** argv, int first, ConvertOptions& options,
                    unsigned* curve_samples = nullptr, PreviewRegion* region = nullptr);

int convert_command(int argc, char** argv);
int curve_command(int argc, char** argv);
int schema_command(int argc, char** argv);
int display_curve_command(int argc, char** argv);

int probe_command(int argc, char** argv);
int inspect_command(int argc, char** argv);
int verify_command(int argc, char** argv);
int thumbnail_command(int argc, char** argv);
int raw_metadata_command(int argc, char** argv);

void set_stdout_binary();

int model_gain_command(int argc, char** argv);
int model_list_command(int argc, char** argv);
int model_input_command(int argc, char** argv);

int preview_frame_command(int argc, char** argv, PreviewSession* session = nullptr,
                          std::vector<std::uint8_t>* packet = nullptr);
int preview_worker_command();

}  // namespace hyperdr::app::detail
