#pragma once

#include <unistd.h>
#include <filesystem>
#include <stdexcept>
#include <system_error>
#include <vector>

namespace hyperdr::test {
// One private directory per test process, including concurrent runs of the same
// executable. All fixtures live below it and are removed on normal/exceptional
// exit; a failed test cannot delete another process's fixtures.
inline const std::filesystem::path& temporary_directory() {
  struct Directory {
    std::filesystem::path path;
    Directory() {
      const auto pattern = (std::filesystem::temp_directory_path() /
                            "hyperdr-test-XXXXXX").string();
      std::vector<char> buffer(pattern.begin(), pattern.end());
      buffer.push_back('\0');
      const auto created = ::mkdtemp(buffer.data());
      if (!created) throw std::runtime_error("cannot create private test directory");
      path = created;
    }
    ~Directory() {
      std::error_code error;
      std::filesystem::remove_all(path, error);
    }
  };
  static const Directory directory;
  return directory.path;
}
}  // namespace hyperdr::test
