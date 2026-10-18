#pragma once
#include "hyperdr/foundation/file_io.hpp"
#include <map>
#include <memory>
#include <sstream>

namespace hyperdr {
// Immutable file contents captured before a conversion can invoke callbacks.
struct ResourceSnapshot {
  std::vector<std::uint8_t> bytes;
  std::string sha256;
};
using ResourceSnapshots = std::map<std::filesystem::path, ResourceSnapshot>;
inline std::vector<std::uint8_t> resource_bytes(const std::filesystem::path& path,
                                             const ResourceSnapshot* snapshot) {
  return snapshot ? snapshot->bytes : read_binary_file(path);
}
inline std::istringstream resource_stream(const std::filesystem::path& path,
                                         const ResourceSnapshot* snapshot) {
  if (snapshot) return std::istringstream(std::string(snapshot->bytes.begin(), snapshot->bytes.end()));
  const auto bytes = read_binary_file(path);
  return std::istringstream(std::string(bytes.begin(), bytes.end()));
}
}  // namespace hyperdr
