#include "../../../tests/support/temp_directory.hpp"
// A 61 MP story card (10200x18134, 1445 HEIF items in the Adaptive file) must
// export, pass the write-time verification of the native HEIF reader and open
// again. libheif refused this file at 1000 items; the export used to stop at
// the verification step.
#include "hyperdr/app/engine.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

#ifndef __has_feature
#define __has_feature(feature) 0
#endif

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

std::filesystem::path write_source(const std::filesystem::path& root) {
  using namespace hyperdr;
  const auto source = root / "source.tif";
  FloatImage photo(9504, 6336, 3);
  for (unsigned y = 0; y < photo.height; ++y)
    for (unsigned x = 0; x < photo.width; ++x) {
      // A smooth ramp with a bright patch, so the gain map is not empty.
      const bool bright = x > 6500 && x < 8500 && y > 1000 && y < 2500;
      for (unsigned c = 0; c < 3; ++c)
        photo.at(x, y, c) = bright ? .95F : .08F + .6F * static_cast<float>(x) / photo.width * (1 + .1F * c);
    }
  write_binary_file_atomic(source, encode_sdr_tiff(photo, {}), true);
  return source;
}

void check(int depth, const std::filesystem::path& source, const std::filesystem::path& root) {
  using namespace hyperdr;
  ConvertOptions options;
  options.input = source;
  options.encoding = OutputEncoding::Adaptive;
  options.depth = depth;
  options.overwrite = true;
  options.output_directory = root / ("story" + std::to_string(depth));
  options.frame = parse_frame_spec(json::parse(R"({"margins":{"top":0.055,"right":0.055,
    "bottom":0.04,"left":0.055},"caption":0.16,"reference":"short",
    "aspect":{"width":9,"height":16,"topShare":0.42}})"));
  Engine engine;
  const auto report = json::parse(engine.convert(options));
  const auto& file = report.find("files")->array().at(0);
  require(file.find("success")->boolean(), "story Adaptive export failed");
  const auto& photo = *file.find("frame")->find("photo");
  require(photo.find("width")->number() == 9504 && photo.find("height")->number() == 6336,
          "story layout moved the photo");
  const auto output = path_from_utf8(file.find("output")->string());
  verify_heic_decodable(output);
  RawDecodeOptions open;
  open.preview_max_edge = 1600;
  const auto reopened = decode_image(output, open).linear_p3;
  require(reopened.width > 0 && reopened.height > reopened.width, "story file reopened with a wrong shape");
  require(reopened.width * 2 < 10200, "story preview was not reduced");
}
}
int main() try {
#if __has_feature(address_sanitizer)
  // A 61 MP canvas costs several gigabytes and minutes under ASan; the plain
  // build runs it, and heif_input_test covers the reader on the same canvas.
  std::cout << "story_export_test skipped under AddressSanitizer\n";
  return 0;
#endif
  const auto folder = hyperdr::test::temporary_directory() /
      ("hyperdr-story-export-" + std::to_string(getpid()));
  try {
    std::filesystem::create_directories(folder);
    const auto source = write_source(folder);
    check(8, source, folder);
    check(10, source, folder);
    std::filesystem::remove_all(folder);
    std::cout << "story_export_test passed\n";
  } catch (const std::exception& error) {
    std::filesystem::remove_all(folder);
    std::cerr << "story_export_test: " << error.what() << '\n';
    return 1;
  }
} catch (const std::exception& error) {
  std::cerr << "test failure: " << error.what() << '\n';
  return 1;
} catch (...) {
  std::cerr << "unknown test failure\n";
  return 1;
}
