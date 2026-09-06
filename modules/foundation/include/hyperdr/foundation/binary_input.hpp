#pragma once

#include <cstdio>
#include <filesystem>
#include <memory>

namespace hyperdr {

// Bulk reads for local float caches; avoids MSVC filebuf's measured overhead.
class BinaryInput {
 public:
  explicit BinaryInput(const std::filesystem::path& path) {
#ifdef _WIN32
    std::FILE* file = nullptr;
    _wfopen_s(&file, path.c_str(), L"rb");
#else
    std::FILE* file = std::fopen(path.c_str(), "rb");
#endif
    file_.reset(file);
  }

  explicit operator bool() const { return file_ != nullptr; }

  bool read(void* output, std::size_t bytes) {
    return file_ && (bytes == 0 || std::fread(output, 1, bytes, file_.get()) == bytes);
  }

 private:
  std::unique_ptr<std::FILE, decltype(&std::fclose)> file_{nullptr, &std::fclose};
};

}  // namespace hyperdr
