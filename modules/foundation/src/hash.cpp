#include "hyperdr/foundation/hash.hpp"
#include "hyperdr/foundation/cancel.hpp"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <iomanip>
#include <limits>
#include <sstream>
#include <stdexcept>
#include <vector>

namespace hyperdr {

std::string fnv1a_hex(std::string_view text) {
  std::uint64_t hash = 1469598103934665603ULL;
  for (std::size_t offset = 0; offset < text.size(); offset += 65536) {
    check_cancelled();
    for (const unsigned char c : text.substr(offset, 65536)) {
      hash ^= static_cast<std::uint64_t>(c);
      hash *= 1099511628211ULL;
    }
  }
  std::array<char, 17> buffer{};
  std::snprintf(buffer.data(), buffer.size(), "%016llx",
                static_cast<unsigned long long>(hash));
  return buffer.data();
}

namespace {

// CommonCrypto (libSystem) does the compression rounds. CC_LONG is 32 bits,
// so callers must feed it bounded chunks rather than a whole file at once.
struct Sha256 {
  CC_SHA256_CTX context{};

  Sha256() { CC_SHA256_Init(&context); }

  void update(const std::uint8_t* data, std::size_t size) {
    static_assert(kChunk <= std::numeric_limits<CC_LONG>::max());
    while (size != 0) {
      const auto amount = std::min(size, kChunk);
      CC_SHA256_Update(&context, data, static_cast<CC_LONG>(amount));
      data += amount; size -= amount;
    }
  }

  std::string finish() {
    std::array<unsigned char, CC_SHA256_DIGEST_LENGTH> digest{};
    CC_SHA256_Final(digest.data(), &context);
    std::ostringstream text;
    text << std::hex << std::setfill('0');
    for (const auto byte : digest) text << std::setw(2) << static_cast<unsigned>(byte);
    return text.str();
  }

  static constexpr std::size_t kChunk = 1024 * 1024;
};

}  // namespace

std::string sha256_hex(std::span<const std::uint8_t> bytes) {
  Sha256 hash;
  for (std::size_t offset = 0; offset < bytes.size(); offset += 65536) {
    check_cancelled();
    const auto chunk = bytes.subspan(offset, std::min<std::size_t>(65536, bytes.size() - offset));
    hash.update(chunk.data(), chunk.size());
  }
  return hash.finish();
}

std::string sha256_file_hex(const std::filesystem::path& path) {
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("cannot open file for hashing");
  Sha256 hash;
  // Heap, not stack: engine entry points run on 512 KB threads.
  std::vector<std::uint8_t> buffer(1024 * 1024);
  while (input) {
    check_cancelled();
    input.read(reinterpret_cast<char*>(buffer.data()), buffer.size());
    const auto count = input.gcount();
    if (count > 0) hash.update(buffer.data(), static_cast<std::size_t>(count));
  }
  if (!input.eof()) throw std::runtime_error("cannot read file for hashing");
  return hash.finish();
}

}  // namespace hyperdr
