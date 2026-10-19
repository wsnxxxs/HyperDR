// R7-502: an external gain grid larger than the photograph is averaged down when
// an unframed Adaptive HEIC is packaged. The export succeeding is not enough:
// the HDR picture ImageIO reconstructs (what Photos shows) must still follow the
// grid. The reference is the same grid exported as PQ, where the grid is applied
// by our own render at the photo's size.
#include "../../../tests/support/temp_directory.hpp"
#include "hyperdr/app/engine.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using namespace hyperdr;
void require(bool ok, const std::string& message) { if (!ok) throw std::runtime_error(message); }

enum class Shape { Smooth, Edge };

// A v2 (signed log2 gain) grid, gamma 1, range [-0.5, 2.0] stops, on a
// non-square lattice: a gradient in both directions, or a step along x.
void write_grid(const std::filesystem::path& directory, unsigned width, unsigned height, Shape shape) {
  std::filesystem::create_directories(directory);
  std::vector<float> values(std::size_t(width) * height);
  for (unsigned y = 0; y < height; ++y)
    for (unsigned x = 0; x < width; ++x) {
      const float u = (float(x) + .5F) / float(width), v = (float(y) + .5F) / float(height);
      values[std::size_t(y) * width + x] = shape == Shape::Edge ? (u > .5F ? 1.5F : 0.F) : -.4F + 2.2F * (.7F * u + .3F * v);
    }
  std::ofstream(directory / "gain.f32", std::ios::binary)
      .write(reinterpret_cast<const char*>(values.data()), std::streamsize(values.size() * sizeof(float)));
  std::ofstream report(directory / "gain.json");
  report << "{\"gain_grid_size\":[" << width << "," << height << "],"
         << "\"label_contract_id\":\"hyperdr.apple-gain-label/v2\","
         << "\"gain_file\":{\"format\":\"raw_float32_with_required_json_sidecar\",\"endianness\":\"little\","
         << "\"scale\":\"signed_log2_gain\",\"width\":" << width << ",\"height\":" << height
         << ",\"byte_length\":" << values.size() * 4 << "},"
         << R"("gain_metadata":{"minimum_version":0,"writer_version":0,"flags":64,"use_base_color_space":true,)"
         << R"("backward_direction":false,"common_denominator":false,)"
         << R"("base_headroom":{"numerator":0,"denominator":1000000},"alternate_headroom":{"numerator":2000000,"denominator":1000000},)"
         << R"("gain_min":{"numerator":-500000,"denominator":1000000},"gain_max":{"numerator":2000000,"denominator":1000000},)"
         << R"("gamma":{"numerator":1000000,"denominator":1000000},"base_offset":{"numerator":0,"denominator":1000000},)"
         << R"("alternate_offset":{"numerator":0,"denominator":1000000}}})" << "\n";
}

struct Luminance { unsigned width{}, height{}; std::vector<double> values; };

// ImageIO's HDR reconstruction in extended linear Display P3, as luminance.
Luminance decode_hdr(const std::filesystem::path& path) {
  const auto text = path.string();
  auto url = CFURLCreateFromFileSystemRepresentation(nullptr, reinterpret_cast<const UInt8*>(text.data()),
                                                     CFIndex(text.size()), false);
  auto source = CGImageSourceCreateWithURL(url, nullptr);
  CFRelease(url);
  require(source != nullptr, "ImageIO does not recognise " + text);
  const void* keys[] = {kCGImageSourceDecodeRequest};
  const void* values[] = {kCGImageSourceDecodeToHDR};
  auto options = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                    &kCFTypeDictionaryValueCallBacks);
  auto image = CGImageSourceCreateImageAtIndex(source, 0, options);
  CFRelease(options);
  CFRelease(source);
  require(image != nullptr, "ImageIO cannot decode " + text);
  Luminance out;
  out.width = unsigned(CGImageGetWidth(image));
  out.height = unsigned(CGImageGetHeight(image));
  auto space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearDisplayP3);
  std::vector<float> pixels(std::size_t(out.width) * out.height * 4);
  auto context = CGBitmapContextCreate(pixels.data(), out.width, out.height, 32, std::size_t(out.width) * 16, space,
                                       kCGImageAlphaPremultipliedLast | kCGBitmapFloatComponents |
                                           kCGBitmapByteOrder32Little);
  CGColorSpaceRelease(space);
  require(context != nullptr, "cannot create the ImageIO comparison context");
  CGContextDrawImage(context, CGRectMake(0, 0, out.width, out.height), image);
  CGContextRelease(context);
  CGImageRelease(image);
  out.values.resize(std::size_t(out.width) * out.height);
  for (std::size_t i = 0; i < out.values.size(); ++i)
    out.values[i] = .2627 * pixels[i * 4] + .678 * pixels[i * 4 + 1] + .0593 * pixels[i * 4 + 2];
  return out;
}

std::filesystem::path export_one(const std::filesystem::path& input, const std::filesystem::path& grid,
                                 const std::filesystem::path& directory, OutputEncoding encoding, int depth) {
  Engine engine({});
  ConvertOptions options;
  options.input = input;
  options.output_directory = directory;
  options.encoding = encoding;
  options.depth = depth;
  options.external_gain_path = grid / "gain.f32";
  options.external_gain_report = grid / "gain.json";
  const auto report = json::parse(engine.convert(options));
  const auto& files = report.find("files")->array();
  require(files.size() == 1, "expected one exported file");
  const auto& file = files.front();
  require(file.find("success")->boolean(),
          file.find("detail") ? file.find("detail")->string() : std::string("export failed"));
  return path_from_utf8(file.find("output")->string());
}

void run() {
  const auto root = hyperdr::test::temporary_directory() / "external-gain-hdr";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root);
  const auto input = root / "photo.tif";
  {
    FloatImage photo(128, 128, 3);
    std::fill(photo.pixels.begin(), photo.pixels.end(), .8F);
    write_binary_file_atomic(input, encode_sdr_tiff(photo, {}), true);
  }
  struct Case { const char* name; unsigned width, height; Shape shape; };
  // Grids beyond the photo on one axis or both, none of them the photo's shape.
  // An aspect-preserving shrink of 64x300 gives 27x128 and smears the step in x
  // over 64 -> 27 columns: mean 0.040 / worst 0.81 stop. Clamping each axis on
  // its own (64x128) measured 0.007 / 0.047.
  for (const Case c : {Case{"edge-tall", 64, 300, Shape::Edge}, Case{"smooth-wide", 300, 64, Shape::Smooth},
                       Case{"smooth-fine", 512, 512, Shape::Smooth}, Case{"edge-fine", 256, 512, Shape::Edge}}) {
    const auto grid = root / c.name;
    write_grid(grid, c.width, c.height, c.shape);
    const auto reference_path = export_one(input, grid, root / (std::string("pq-") + c.name), OutputEncoding::Pq, 10);
    const auto reference = decode_hdr(reference_path);
    double peak = 0;
    for (const double v : reference.values) peak = std::max(peak, v);
    require(peak > 1.2, std::string(c.name) + ": the reference has no HDR headroom, the comparison would prove nothing");
    for (const int depth : {8, 10}) {
      const auto adaptive = decode_hdr(export_one(input, grid, root / (std::string("ad-") + c.name + std::to_string(depth)),
                                                  OutputEncoding::Adaptive, depth));
      require(adaptive.width == reference.width && adaptive.height == reference.height,
              std::string(c.name) + ": Adaptive size differs from the reference");
      double sum = 0, worst = 0, adaptive_peak = 0;
      for (std::size_t i = 0; i < adaptive.values.size(); ++i) {
        const double d = std::fabs(std::log2((adaptive.values[i] + 1e-3) / (reference.values[i] + 1e-3)));
        sum += d;
        worst = std::max(worst, d);
        adaptive_peak = std::max(adaptive_peak, adaptive.values[i]);
      }
      const double mean = sum / double(adaptive.values.size());
      const auto label = std::string(c.name) + " depth " + std::to_string(depth) + ": mean |dlog2| " +
                         std::to_string(mean) + ", worst " + std::to_string(worst);
      // Measured 0.008-0.010 / 0.04-0.06 for every case here; the failure this
      // guards against (a mis-scaled or flipped grid) is several times larger.
      require(mean < .02 && worst < .15, label);
      require(std::fabs(std::log2(adaptive_peak / peak)) < .1, label + " (peak differs)");
    }
  }
  std::filesystem::remove_all(root);
}
}  // namespace

int main() try {
  run();
  std::cout << "external_gain_hdr_test passed\n";
} catch (const std::exception& e) {
  std::cerr << e.what() << '\n';
  return 1;
}
