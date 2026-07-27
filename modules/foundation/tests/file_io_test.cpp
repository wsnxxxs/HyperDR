// Path comparison is shared by output-collision detection, self-overwrite
// refusal, and the discovery walk that must not descend into its own output.
// It used to exist in two copies with different platform behaviour.
#include "hyperdr/foundation/file_io.hpp"

#include <cstdint>
#include <filesystem>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_path_comparison() {
  const std::filesystem::path root = "out";
  require(hyperdr::same_path("out", "./out"), "a redundant ./ changed the path key");
  require(hyperdr::is_same_or_descendant("out/nested/file.heic", root),
          "a descendant was not recognised");
  require(hyperdr::is_same_or_descendant(root, root), "a path was not its own root");
  require(!hyperdr::is_same_or_descendant("output-elsewhere", root),
          "a sibling sharing a name prefix was treated as a descendant");
}

void test_extension_is_case_insensitive() {
  require(hyperdr::lower_extension("PHOTO.ARW") == ".arw", "extension was not folded");
  require(hyperdr::lower_extension("photo.tar.gz") == ".gz", "compound extension failed");
  require(hyperdr::lower_extension("noextension").empty(), "missing extension failed");
}

void test_atomic_write_round_trips() {
  const auto directory = std::filesystem::temp_directory_path() / "hyperdr-file-io-test";
  std::filesystem::remove_all(directory);
  const auto target = directory / "nested" / "value.bin";
  const std::vector<std::uint8_t> bytes{1, 2, 3, 4};
  hyperdr::write_binary_file_atomic(target, bytes, false);
  require(hyperdr::read_binary_file(target) == bytes, "written bytes did not round trip");

  bool refused = false;
  try {
    hyperdr::write_binary_file_atomic(target, bytes, false);
  } catch (const std::exception&) {
    refused = true;
  }
  require(refused, "an existing output was overwritten without permission");
  hyperdr::write_text_file_atomic(target, "replaced", true);
  require(hyperdr::read_binary_file(target).size() == 8, "overwrite did not replace");
  // No temporary may survive a successful publish.
  for (const auto& entry : std::filesystem::directory_iterator(target.parent_path())) {
    require(entry.path().filename() == target.filename(),
            "a temporary file was left behind");
  }
  std::filesystem::remove_all(directory);
}

}  // namespace

int main() {
  try {
    test_path_comparison();
    test_extension_is_case_insensitive();
    test_atomic_write_round_trips();
    std::cout << "file IO tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
