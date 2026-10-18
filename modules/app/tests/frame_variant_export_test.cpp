// The variant changes only the mat: the TIFF's decoded photograph stays exact.
#include "hyperdr/app/engine.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <unistd.h>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
void check(unsigned width, const std::filesystem::path& root) {
  using namespace hyperdr;
  FloatImage original(width, 100, 3);
  for (unsigned y = 0; y < original.height; ++y)
    for (unsigned x = 0; x < width; ++x)
      for (unsigned c = 0; c < 3; ++c)
        original.at(x,y,c) = .05F + .8F * static_cast<float>((x*13+y*7+c*3)%101)/100;
  const auto source = root / "source.tif";
  write_binary_file_atomic(source, encode_sdr_tiff(original, {}), true);
  ConvertOptions options;
  options.input = source;
  options.encoding = OutputEncoding::SdrTiff;
  options.output_directory = root / "plain";
  options.overwrite = true;
  Engine engine;
  const auto plain_report = json::parse(engine.convert(options));
  const auto& plain_file = plain_report.find("files")->array().at(0);
  require(plain_file.find("success")->boolean(), "unframed TIFF conversion failed");
  const auto plain = decode_image(path_from_utf8(plain_file.find("output")->string()), {}).linear_p3;
  options.frame = parse_frame_spec(json::parse(R"({"margins":0.055,"caption":0.16,
    "aspect":{"width":9,"height":16},"variants":{"wide":{"minRatio":2.5,
    "reference":"long","margins":0.02,"caption":0.06,"aspect":null}}})"));
  options.output_directory = root / "framed";
  const auto framed_report = json::parse(engine.convert(options));
  const auto& framed_file = framed_report.find("files")->array().at(0);
  require(framed_file.find("success")->boolean(), "wide TIFF conversion failed");
  require(framed_file.find("frame")->find("variant")->string() == "wide", "report omitted variant");
  const auto framed = decode_image(path_from_utf8(framed_file.find("output")->string()), {}).linear_p3;
  const auto layout = layout_frame(*options.frame, width, 100);
  for (unsigned y = 0; y < plain.height; ++y)
    for (unsigned x = 0; x < plain.width; ++x)
      for (unsigned c = 0; c < 3; ++c)
        require(plain.at(x,y,c) == framed.at(x+layout.photo.x,y+layout.photo.y,c),
                "wide TIFF changed a photograph pixel");
}
}
int main() {
  const auto folder = std::filesystem::temp_directory_path() /
      ("hyperdr-frame-variant-export-" + std::to_string(getpid()));
  try {
    std::filesystem::create_directories(folder);
    check(400,folder); check(1000,folder);
    std::filesystem::remove_all(folder);
    std::cout << "frame_variant_export_test passed\n";
  } catch (const std::exception& error) {
    std::filesystem::remove_all(folder);
    std::cerr << "frame_variant_export_test: " << error.what() << '\n';
    return 1;
  }
}
