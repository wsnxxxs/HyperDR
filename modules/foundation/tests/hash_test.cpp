#include "hyperdr/foundation/hash.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void check_sha256_vectors() {
  const auto path = std::filesystem::temp_directory_path() / "hyperdr-sha256-test.bin";
  { std::ofstream output(path, std::ios::binary | std::ios::trunc); }
  require(hyperdr::sha256_file_hex(path) ==
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "SHA-256 empty-file vector failed");
  {
    std::ofstream output(path, std::ios::binary | std::ios::trunc);
    output << "abc";
  }
  require(hyperdr::sha256_file_hex(path) ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "SHA-256 abc vector failed");
  std::filesystem::remove(path);
}

}  // namespace

int main() {
  try {
    check_sha256_vectors();
    std::cout << "hash tests passed\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
