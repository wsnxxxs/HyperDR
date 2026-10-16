#include "hyperdr/foundation/file_io.hpp"
#include "file_io_platform.hpp"

#include <atomic>
#include <fstream>
#include <stdexcept>
#include <system_error>

#include <windows.h>

namespace hyperdr {
namespace {

std::filesystem::path unique_temporary_for(const std::filesystem::path& path) {
  static std::atomic_uint64_t sequence{0};
  const auto process_id = static_cast<std::uint64_t>(GetCurrentProcessId());
  std::filesystem::path temporary;
  do {
    temporary = path;
    temporary += ".tmp." + std::to_string(process_id) + "." +
                 std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
  } while (std::filesystem::exists(temporary));
  return temporary;
}

void publish(const std::filesystem::path& temporary,
             const std::filesystem::path& path, bool overwrite) {
  DWORD flags = MOVEFILE_WRITE_THROUGH;
  if (overwrite) flags |= MOVEFILE_REPLACE_EXISTING;
  if (!MoveFileExW(temporary.c_str(), path.c_str(), flags)) {
    const auto error = static_cast<int>(GetLastError());
    std::error_code ignored;
    std::filesystem::remove(temporary, ignored);
    throw std::system_error(error, std::system_category(),
                            "cannot atomically publish output");
  }
}

}  // namespace

namespace detail {

void write_bytes_atomic(const std::filesystem::path& path, const char* data,
                        std::size_t size, bool overwrite) {
  if (!overwrite && std::filesystem::exists(path)) {
    throw std::runtime_error("output exists: " + path_utf8(path));
  }
  if (!path.parent_path().empty()) {
    std::filesystem::create_directories(path.parent_path());
  }
  const auto temporary = unique_temporary_for(path);
  {
    std::ofstream out(temporary, std::ios::binary | std::ios::trunc);
    const auto fail = [&](const char* message) {
      out.close();
      std::error_code ignored;
      std::filesystem::remove(temporary, ignored);
      throw std::runtime_error(message);
    };
    if (!out || (size != 0 &&
                 !out.write(data, static_cast<std::streamsize>(size)))) {
      fail("cannot write temporary output");
    }
    out.flush();
    if (!out) fail("cannot flush temporary output");
  }
  publish(temporary, path, overwrite);
}

}  // namespace detail

std::uint64_t available_memory_bytes() {
  MEMORYSTATUSEX status{};
  status.dwLength = sizeof(status);
  if (GlobalMemoryStatusEx(&status) != 0) {
    return static_cast<std::uint64_t>(status.ullAvailPhys);
  }
  return 0;
}

}  // namespace hyperdr
