#include "hyperdr/app/discovery.hpp"

#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <algorithm>
#include <cctype>
#include <array>
#include <stdexcept>

namespace hyperdr {
namespace {

constexpr std::array<std::string_view, 6> kRasterExtensions{
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".avif"};

// This converter's own outputs end in "-hyperdr". When the output directory is
// the input directory, skipping them is what stops a second run from converting
// its own results.
bool has_generated_output_name(const std::filesystem::path& path) {
  auto stem = path_utf8(path.stem());
  std::transform(stem.begin(), stem.end(), stem.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return stem.ends_with("-hyperdr");
}

}  // namespace

std::vector<std::string_view> supported_input_extensions() {
  std::vector<std::string_view> extensions;
  extensions.reserve(kRawInputExtensions.size() + kRasterExtensions.size());
  extensions.insert(extensions.end(), kRawInputExtensions.begin(),
                    kRawInputExtensions.end());
  extensions.insert(extensions.end(), kRasterExtensions.begin(),
                    kRasterExtensions.end());
  return extensions;
}

bool is_supported_input(const std::filesystem::path& path) {
  const auto extension = lower_extension(path);
  return is_raw_extension(extension) ||
         std::find(kRasterExtensions.begin(), kRasterExtensions.end(), extension) !=
             kRasterExtensions.end();
}

std::vector<std::filesystem::path> discover_input_files(const ConvertOptions& options) {
  std::vector<std::filesystem::path> files;
  const bool directory_input = std::filesystem::is_directory(options.input);
  const bool output_is_input =
      directory_input && same_path(options.output_directory, options.input);
  const bool output_is_nested =
      directory_input && !output_is_input &&
      is_same_or_descendant(options.output_directory, options.input);

  const auto accept = [&](const std::filesystem::path& path) {
    if (!is_supported_input(path)) return;
    if (output_is_input && has_generated_output_name(path)) return;
    files.push_back(path);
  };

  if (std::filesystem::is_regular_file(options.input)) {
    accept(options.input);
  } else if (directory_input && options.recursive) {
    std::filesystem::recursive_directory_iterator child(options.input), end;
    for (; child != end; ++child) {
      if (output_is_nested && child->is_directory() &&
          same_path(child->path(), options.output_directory)) {
        child.disable_recursion_pending();
        continue;
      }
      if (child->is_regular_file()) accept(child->path());
    }
  } else if (directory_input) {
    for (const auto& child : std::filesystem::directory_iterator(options.input)) {
      if (child.is_regular_file()) accept(child.path());
    }
  } else {
    throw std::runtime_error("input path does not exist: " + path_utf8(options.input));
  }

  std::sort(files.begin(), files.end());
  if (files.empty()) {
    throw std::runtime_error(
        "no supported images found (LibRaw RAW, JPG, JPEG, PNG, HEIC, HEIF, AVIF)");
  }
  return files;
}

std::filesystem::path output_path_for(const std::filesystem::path& input,
                                      const ConvertOptions& options) {
  std::filesystem::path relative;
  if (std::filesystem::is_directory(options.input)) {
    relative = std::filesystem::relative(input, options.input);
    if (relative.empty() || relative.is_absolute() ||
        *relative.begin() == std::filesystem::path("..")) {
      throw std::runtime_error("input escaped conversion root: " + path_utf8(input));
    }
  } else {
    relative = input.filename();
  }
  relative.replace_extension();
  relative += "-hyperdr";
  relative += hdr_encoding_extension(options.encoding);
  return options.output_directory / relative;
}

}  // namespace hyperdr
