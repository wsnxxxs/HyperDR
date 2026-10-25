#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include "hyperdr/hyperdr.h"

#include <filesystem>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <unistd.h>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

struct Engine {
  hyperdr_engine* value = nullptr;
  Engine() {
    hyperdr_error* error = nullptr;
    require(hyperdr_engine_create(nullptr, &value, &error) == 0, "engine creation failed");
  }
  ~Engine() { hyperdr_engine_destroy(value); }
};

std::string convert(Engine& engine, const std::string& raw, const std::string& dng) {
  char* report = nullptr;
  hyperdr_error* error = nullptr;
  const int result = hyperdr_raw_convert_dng(engine.value, raw.c_str(), dng.c_str(),
                                             nullptr, &report, &error);
  if (result) {
    const std::string message = error ? error->message : "DNG conversion failed";
    hyperdr_error_free(error);
    throw std::runtime_error(message);
  }
  std::string text = report;
  hyperdr_string_free(report);
  return text;
}

std::string preview(Engine& engine, const std::string& raw, const std::string& jpeg) {
  char* report = nullptr;
  hyperdr_error* error = nullptr;
  const int result = hyperdr_raw_extract_preview(engine.value, raw.c_str(), jpeg.c_str(),
                                                 nullptr, &report, &error);
  if (result) {
    const std::string message = error ? error->message : "preview extraction failed";
    hyperdr_error_free(error);
    throw std::runtime_error(message);
  }
  std::string text = report;
  hyperdr_string_free(report);
  return text;
}

void check_developed(const std::string& path, unsigned width, unsigned height, unsigned orientation) {
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    const bool swaps = orientation >= 5 && orientation <= 8;
    const double expected_width = swaps ? height : width;
    const double expected_height = swaps ? width : height;
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    require(source, "ImageIO did not open the converted DNG");
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    CFRelease(source);
    require([properties[(__bridge NSString*)kCGImagePropertyPixelWidth] doubleValue] == width,
            "ImageIO reported the wrong DNG width");
    require([properties[(__bridge NSString*)kCGImagePropertyPixelHeight] doubleValue] == height,
            "ImageIO reported the wrong DNG height");
    NSDictionary* exif = properties[(__bridge NSString*)kCGImagePropertyExifDictionary];
    require(exif[@"ExposureBiasValue"] != nil, "DNG EXIF lost ExposureBiasValue");
    require(exif[@"DateTimeOriginal"] != nil, "DNG EXIF lost DateTimeOriginal");

    CIRAWFilter* filter = [CIRAWFilter filterWithImageURL:url];
    CIImage* image = filter.outputImage;
    require(image && !CGRectIsEmpty(image.extent), "CIRAWFilter did not develop the converted DNG");
    require(image.extent.size.width == expected_width && image.extent.size.height == expected_height,
            "CIRAWFilter reported the wrong developed dimensions");
  }
}

void check_preview(const std::string& path) {
  @autoreleasepool {
    NSURL* url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, nullptr);
    require(source, "ImageIO did not open the embedded JPEG preview");
    NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
    CFRelease(source);
    require([properties[(__bridge NSString*)kCGImagePropertyPixelWidth] unsignedIntValue] == 1616 &&
            [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] unsignedIntValue] == 1080,
            "embedded preview dimensions changed");
  }
}

struct TempDirectory {
  std::filesystem::path path;
  TempDirectory() {
    const char* tmp = getenv("TMPDIR");
    std::string pattern = std::string(tmp ? tmp : "/tmp") + "/hyperdr-raw-compat-XXXXXX";
    std::vector<char> name(pattern.begin(), pattern.end());
    name.push_back('\0');
    char* created = mkdtemp(name.data());
    require(created, "cannot create RAW compatibility test directory");
    path = created;
  }
  ~TempDirectory() { std::filesystem::remove_all(path); }
};

void suite() {
  const std::filesystem::path root = HYPERDR_SOURCE_DIR;
  TempDirectory temporary;
  Engine engine;
  require(std::string(hyperdr_raw_converter_id()).find("/dng-2") != std::string::npos,
          "unexpected RAW converter id");
  struct Fixture {
    const char* file;
    unsigned width, height, orientation;
    const char* make;
    const char* model;
  };
  const Fixture fixtures[] = {
      {"sony-ilce-7s.ARW", 2768, 1848, 1, "Sony", "ILCE-7S"},
      {"leica-c-portrait.RWL", 4000, 2672, 6, "Leica", "C (Typ 112)"},
  };
  for (const auto& fixture : fixtures) {
    const auto raw = root / "build/fixtures" / fixture.file;
    const auto dng = temporary.path / (std::string(fixture.file) + ".dng");
    const auto report = convert(engine, raw, dng);
    require(report.find("\"layout\":\"cfa\"") != std::string::npos, "Bayer RAW was not written as CFA");
    require(report.find(std::string("\"make\":\"") + fixture.make) != std::string::npos,
            "DNG report lost the camera make");
    require(report.find(std::string("\"model\":\"") + fixture.model) != std::string::npos,
            "DNG report lost the camera model");
    check_developed(dng, fixture.width, fixture.height, fixture.orientation);

    const auto before = std::filesystem::file_size(dng);
    char* report_again = nullptr;
    hyperdr_error* error = nullptr;
    require(hyperdr_raw_convert_dng(engine.value, raw.c_str(), dng.c_str(), nullptr,
                                    &report_again, &error) != 0,
            "DNG conversion overwrote an existing destination");
    require(!report_again && error, "exclusive DNG creation did not return an error");
    hyperdr_error_free(error);
    require(std::filesystem::file_size(dng) == before, "existing DNG changed after a refused conversion");
  }

  const auto raw = root / "build/fixtures/sony-ilce-7s.ARW";
  const auto jpeg = temporary.path / "preview.jpg";
  const auto report = preview(engine, raw, jpeg);
  require(report.find("\"width\":1616") != std::string::npos &&
          report.find("\"height\":1080") != std::string::npos,
          "largest embedded preview was not selected");
  check_preview(jpeg);
  for (const auto& entry : std::filesystem::directory_iterator(temporary.path)) {
    require(entry.path().filename().string().find(".tmp.") == std::string::npos,
            "RAW compatibility left a temporary artifact");
  }
}

}  // namespace

int main(int argc, char** argv) {
  @autoreleasepool {
    try {
      if (argc == 3) {
        // Native one-shot mode for timing and peak-RSS measurements with /usr/bin/time.
        Engine engine;
        std::cout << convert(engine, argv[1], argv[2]);
        return 0;
      }
      if (argc != 1) return 2;
      suite();
      return 0;
    } catch (const std::exception& error) {
      std::cerr << error.what() << '\n';
      return 1;
    }
  }
}
