#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/cancel.hpp"

#include <array>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <pthread.h>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const std::string& message) {
  if (!condition) throw std::runtime_error(message);
}

std::vector<std::uint8_t> pattern(std::size_t size) {
  std::vector<std::uint8_t> bytes(size);
  for (std::size_t i = 0; i < size; ++i)
    bytes[i] = static_cast<std::uint8_t>(i * 167 + 13 + (i >> 8));
  return bytes;
}

void write_file(const std::filesystem::path& path, const std::vector<std::uint8_t>& bytes) {
  std::ofstream output(path, std::ios::binary | std::ios::trunc);
  output.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
  require(static_cast<bool>(output), "cannot write hash test input");
}

// Digests recorded with the previous in-house SHA-256 and checked against
// Python's hashlib; lengths straddle the 55/56-byte padding split, the 64-byte
// block and the 64 KiB memory chunk.
struct Vector { std::size_t size; const char* digest; };
constexpr std::array<Vector, 11> kVectors{{
    {0, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
    {1, "9d1e0e2d9459d06523ad13e28a4093c2316baafe7aec5b25f30eba2e113599c4"},
    {55, "b2ca0adc388a66d3a5a7f6541239331d5a867eede554e11262241271faaf36c5"},
    {56, "3768eff44f1df02704a832cf708935fbed9bb74d0714fbe75454c266c4e12856"},
    {63, "dc06ea9e456da9f9fc2276564018231c36196ff7745bf505fd7f503aec5c67fd"},
    {64, "b68fe543b0b5a544e32eb08712e697bfcd3a3cb491563c3b1cba112d378f4bdb"},
    {65, "587cdb9ad9be371721f2f84a84eb09f2b698ec19bbe2d7c222179996547a04a6"},
    {65535, "850518ededf069a11fd79e5706fbfd03ecfd42ad2d7a33f63e9e409e16715b75"},
    {65536, "941c078920a0559d29a1aa7dd9c3b626f1f54c7f27b93dab2519091d5d41065c"},
    {65537, "8ca05c5288efa854305bd4c4b1e13508ee229cd44a4e707663e688f1f41bc713"},
    {1048576, "2b6f8fc446d2e3a8202eddc679bd81ee99e9965cfd899936e0a735c105d80c41"},
}};
struct FileVector { const char* path; const char* digest; };
const std::array<FileVector, 2> kFiles{{
    {HYPERDR_HASH_JPEG, "066af0474199d0a9c60dfdf72f815e03bb7d5cdc2a98fb8259548287c03ae6a3"},
    {HYPERDR_HASH_ARW, "a35ebb2fbec929daa5beb20d1ce5c15a8aac7b1a7a231455387f3df8a7442e07"},
}};

void check_sha256_vectors() {
  const auto path = std::filesystem::temp_directory_path() / "hyperdr-sha256-test.bin";
  for (const auto& vector : kVectors) {
    const auto bytes = pattern(vector.size);
    write_file(path, bytes);
    const auto label = std::to_string(vector.size) + "-byte SHA-256";
    require(hyperdr::sha256_hex(bytes) == vector.digest, label + " (memory) changed");
    require(hyperdr::sha256_file_hex(path) == vector.digest, label + " (file) changed");
  }
  write_file(path, {'a', 'b', 'c'});
  require(hyperdr::sha256_file_hex(path) ==
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
          "SHA-256 abc vector failed");
  // A file longer than the 1 MiB read buffer, hashed in several reads.
  write_file(path, pattern(3 * 1024 * 1024 + 17));
  require(hyperdr::sha256_file_hex(path) == hyperdr::sha256_hex(pattern(3 * 1024 * 1024 + 17)),
          "multi-read file SHA-256 must match memory");
  {
    hyperdr::CancelToken cancel;
    cancel.request();
    hyperdr::CancelScope scope(&cancel);
    bool cancelled = false;
    try { (void)hyperdr::sha256_file_hex(path); } catch (const hyperdr::Cancelled&) { cancelled = true; }
    require(cancelled, "file SHA-256 must observe cancellation");
  }
  std::filesystem::remove(path);
  bool missing = false;
  try { (void)hyperdr::sha256_file_hex(path); } catch (const std::runtime_error&) { missing = true; }
  require(missing, "missing file must raise runtime_error");
  for (const auto& file : kFiles) {
    require(std::filesystem::is_regular_file(file.path),
            std::string("required hash fixture missing: ") + file.path +
                ". Run python3 scripts/fetch_test_fixtures.py");
    require(hyperdr::sha256_file_hex(file.path) == file.digest,
            std::string("SHA-256 changed for ") + file.path);
  }
}

void* on_small_stack(void* context) {
  auto& error = *static_cast<std::exception_ptr*>(context);
  try { check_sha256_vectors(); } catch (...) { error = std::current_exception(); }
  return nullptr;
}

void check_on_small_stack() {
  std::exception_ptr error;
  pthread_attr_t attributes;
  require(pthread_attr_init(&attributes) == 0, "pthread_attr_init");
  require(pthread_attr_setstacksize(&attributes, 512 * 1024) == 0, "pthread stack size");
  pthread_t thread;
  const auto status = pthread_create(&thread, &attributes, on_small_stack, &error);
  pthread_attr_destroy(&attributes);
  require(status == 0, "pthread_create");
  require(pthread_join(thread, nullptr) == 0, "pthread_join");
  if (error) std::rethrow_exception(error);
}

}  // namespace

int main() {
  try {
    check_sha256_vectors();
    check_on_small_stack();
    std::cout << "hash tests passed: 13 recorded digests, 512 KB stack\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
