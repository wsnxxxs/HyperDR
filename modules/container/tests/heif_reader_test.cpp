#include "hyperdr/container/heif_reader.hpp"

#include <pthread.h>

#include <algorithm>
#include <exception>
#include <iostream>

#include "heif_writer_fixture.hpp"
#include "hyperdr/foundation/file_io.hpp"
using namespace hyperdr;
namespace {
void require(bool valid, const char* message) {
  if (!valid) throw std::runtime_error(message);
}
void run(bool generate) {
  for (const auto& name : writer_fixture::names()) {
    auto bytes = writer_fixture::file(name);
    auto file = read_heif(bytes);
    auto image = file.resolve_image();
    if (generate)
      if (const char* directory = std::getenv("HYPERDR_READER_SEEDS")) {
        auto root = std::filesystem::path(directory);
        std::filesystem::create_directories(root);
        write_binary_file_atomic(root / ("writer-" + name + ".heic"), bytes, true);
      }

    require(image.width == (name == "single8"                                    ? 512U
                            : (name == "grid10-hlg" || name == "adaptive8-grid") ? 700U
                                                                                 : 127U),
            "reader width differs from writer input");
    require(image.tiles.size() == ((name == "grid10-hlg" || name == "adaptive8-grid") ? 4 : 1),
            "reader tile count differs from writer input");
    auto gain = file.resolve_gain_map();
    require(gain.has_value() == name.starts_with("adaptive"),
            "gain map presence differs from writer");
    if (gain) {
      require(gain->metadata.has_value(), "ISO metadata missing");
      require(!file.exif().empty() && !file.xmp().empty(), "metadata lost");
      require(file.tmap_references()->base_id == file.primary_item_id, "tmap order changed");
    }
    auto dump = file.normalized_json();
    auto inspected = inspection_json(inspect_heif(bytes));
    auto path = std::filesystem::path(HYPERDR_READER_GOLDENS) / (name + ".json");
    auto old = path;
    old.replace_extension("inspect.json");
    if (generate) {
      write_binary_file_atomic(path, std::vector<std::uint8_t>(dump.begin(), dump.end()), true);
      write_binary_file_atomic(old, std::vector<std::uint8_t>(inspected.begin(), inspected.end()),
                               true);
    } else {
      auto expected = read_binary_file(path);
      require(std::string(expected.begin(), expected.end()) == dump,
              "reader normalized golden changed");
      auto expected_inspect = read_binary_file(old);
      require(std::string(expected_inspect.begin(), expected_inspect.end()) == inspected,
              "existing inspection_json changed");
    }
  }
  for (unsigned columns = 1; columns <= 3; ++columns)
    for (unsigned rows = 1; rows <= 2; ++rows) {
      auto stream = writer_fixture::sequence(10, columns * rows);
      HeifEncodedImage input{stream,           columns * 512 - 13,          rows * 512 - 11,
                             {9, 18, 9, true}, HeifContentLight{1000, 400}, {}};
      auto bytes = write_heif(input);
      auto file = read_heif(bytes);
      auto plan = file.resolve_image();
      require(plan.columns == columns && plan.rows == rows && plan.width == input.width &&
                  plan.height == input.height,
              "grid writer-reader roundtrip differs");
      require(plan.color && plan.color->primaries == 9 && plan.color->transfer == 18 &&
                  plan.color->matrix == 9 && plan.color->full_range && plan.light &&
                  plan.light->maximum == 1000 && plan.light->average == 400,
              "grid colour/content-light roundtrip differs");
      // Sony HLG stores colr on the coded input rather than the grid.
      // Exercise inheritance without changing the writer's own contract.
      if (file.item(file.primary_item_id).type == "grid") {
        auto inherited = file;
        auto& parent = inherited.items.at(inherited.primary_item_id);
        auto& first = inherited.items.at(plan.tiles.front().id);
        std::erase_if(first.properties, [&](const HeifAssociation& a) {
          const auto& type = inherited.properties.at(a.index - 1).type;
          return type == "colr" || type == "clli";
        });
        std::erase_if(parent.properties, [&](const HeifAssociation& a) {
          const auto& type = inherited.properties.at(a.index - 1).type;
          if (type != "colr" && type != "clli") return false;
          first.properties.push_back(a);
          return true;
        });
        const auto fallback = inherited.resolve_image();
        require(fallback.color && fallback.color->primaries == 9 &&
                    fallback.color->transfer == 18 && fallback.color->matrix == 9 &&
                    fallback.color->full_range && fallback.light &&
                    fallback.light->maximum == 1000 && fallback.light->average == 400,
                "grid lost coded-input colour/content-light properties");
      }
    }
  for (const auto& name : {"fixtures/gamma-1-control", "fixtures/gamma-2-probe",
                           "fixtures-prerepair/gamma-1-control", "fixtures-prerepair/gamma-2-probe",
                           "probes/normal-512x384-repaired", "probes/normal-128x128-ordinary-path",
                           "probes/tiny-8x4-auxrepair-only", "probes/normal-512x384-prerepair"}) {
    auto bytes = read_binary_file(std::filesystem::path(HYPERDR_SOURCE_ROOT) / "tests/macos_t2" /
                                  (std::string(name) + ".heic"));
    auto file = read_heif(bytes);
    auto normalized = file.normalized_json();
    std::string stem = name;
    std::replace(stem.begin(), stem.end(), '/', '_');
    auto root = std::filesystem::path(HYPERDR_READER_GOLDENS);
    auto path = root / (stem + ".json");
    if (generate)
      write_binary_file_atomic(path, {normalized.begin(), normalized.end()}, true);
    else {
      auto expected = read_binary_file(path);
      require(std::string(expected.begin(), expected.end()) == normalized,
              "signed fixture normalized golden changed");
    }
    // Captured with the unmodified 1195083c CLI before the read-path switch.
    auto old = read_binary_file(root / (stem + ".inspect.json"));
    auto inspection = inspection_json(inspect_heif(bytes));
    require(std::string(old.begin(), old.end()) == inspection,
            "signed fixture inspection_json changed");
  }
  // Real-world matrix generated in the isolated spike: this optional mode is
  // useful for development, never a dependency on private sample files in
  // ctest.
  if (const char* path = std::getenv("HYPERDR_READER_SAMPLE")) {
    auto bytes = read_binary_file(path);
    auto file = read_heif(bytes);
    auto p = file.resolve_image();
    auto g = file.resolve_gain_map();
    std::cout << "sample " << p.width << 'x' << p.height << " tiles=" << p.tiles.size()
              << " gain=" << bool(g) << '\n';
  }
}
struct State {
  bool generate{};
  std::exception_ptr error;
};
void* entry(void* context) {
  auto& state = *static_cast<State*>(context);
  try {
    run(state.generate);
  } catch (...) {
    state.error = std::current_exception();
  }
  return nullptr;
}
}  // namespace
int main(int argc, char** argv) {
  try {
    State state{argc == 2 && std::string(argv[1]) == "--generate", {}};
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 512 * 1024);
    pthread_t thread;
    require(pthread_create(&thread, &attr, entry, &state) == 0, "reader pthread failed");
    pthread_join(thread, nullptr);
    pthread_attr_destroy(&attr);
    if (state.error) std::rethrow_exception(state.error);
    std::cout << "HEIF reader goldens and writer roundtrips passed on 512KiB stack\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
