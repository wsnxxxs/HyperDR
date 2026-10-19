#include <pthread.h>

#include <chrono>
#include <exception>
#include <filesystem>
#include <iostream>

#include "hyperdr/container/heif_reader.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/json.hpp"
namespace {
void run() {
  using namespace hyperdr;
  auto root = std::filesystem::path(HYPERDR_MALFORMED_FIXTURES);
  auto bytes = read_binary_file(root / "manifest.json");
  auto manifest = json::parse(std::string(bytes.begin(), bytes.end()));
  for (const auto& entry : manifest.array()) {
    auto name = entry.find("file")->string();
    auto expected = entry.find("code")->string();
    auto feature = entry.find("feature")->string();
    auto specimen = read_binary_file(root / name);
    std::string actual = "ok", actual_feature;
    const auto start = std::chrono::steady_clock::now();
    // Structural fragments take a separate inspect route from full-file reads.
    // Fuzz regression: an 8-byte iref must never form a reversed subspan.
    (void)inspection_json(inspect_heif(specimen));
    try {
      auto file = read_heif(specimen);
      auto image = file.resolve_image();
      auto gain = file.resolve_gain_map();
      auto alpha = file.resolve_alpha();
      if (name == "valid-alpha-1.heic" && (!alpha || !alpha->premultiplied))
        throw std::runtime_error("premultiplied alpha missing");
      if (name == "valid-alpha-2.heic" && (!alpha || alpha->premultiplied))
        throw std::runtime_error("straight alpha missing");
      if (name == "valid-legacy-gain.heic" && (!gain || gain->metadata))
        throw std::runtime_error("legacy gain map missing");
      if (name == "valid-transforms.heic" &&
          (image.transforms.size() != 3 || image.transforms[0].type != "irot" ||
           image.transforms[1].type != "imir" || image.transforms[2].type != "clap" ||
           image.transforms[2].left != 128 || image.transforms[2].top != 192))
        throw std::runtime_error("transform order/geometry differs");
    } catch (const HeifReadError& e) {
      actual = e.code();
      actual_feature = e.feature();
    } catch (const std::exception& e) {
      throw std::runtime_error(name + ": unexpected exception: " + e.what());
    }
    if (actual != expected || actual_feature != feature)
      throw std::runtime_error(name + ": expected " + expected + "/" + feature + ", got " + actual +
                               "/" + actual_feature);
    if (std::chrono::steady_clock::now() - start > std::chrono::seconds(1))
      throw std::runtime_error(name + ": exceeded one second");
  }
  std::cout << manifest.array().size() << " malformed/valid controls passed on 512KiB stack\n";
}
void* entry(void* p) {
  try {
    run();
  } catch (...) {
    *static_cast<std::exception_ptr*>(p) = std::current_exception();
  }
  return nullptr;
}
}  // namespace
int main() {
  try {
    std::exception_ptr error;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_t thread;
    if (pthread_create(&thread, &attr, entry, &error)) throw std::runtime_error("pthread_create");
    pthread_join(thread, nullptr);
    pthread_attr_destroy(&attr);
    if (error) std::rethrow_exception(error);
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
