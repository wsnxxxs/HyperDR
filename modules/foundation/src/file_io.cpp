#include "hyperdr/foundation/file_io.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cwctype>
#include <fstream>
#include <stdexcept>
#include <system_error>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
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

}  // namespace

std::vector<std::uint8_t> read_binary_file(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary | std::ios::ate);
  if (!in) throw std::runtime_error("cannot open input file: " + path_utf8(path));
  const auto size = in.tellg();
  if (size < 0) throw std::runtime_error("cannot determine file size");
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(size));
  in.seekg(0);
  if (!bytes.empty() &&
      !in.read(reinterpret_cast<char*>(bytes.data()), size)) {
    throw std::runtime_error("cannot read input file");
  }
  return bytes;
}

std::vector<std::uint8_t> read_binary_prefix(const std::filesystem::path& path,
                                             std::size_t max_bytes) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::vector<std::uint8_t> bytes(max_bytes);
  in.read(reinterpret_cast<char*>(bytes.data()),
          static_cast<std::streamsize>(max_bytes));
  bytes.resize(static_cast<std::size_t>(in.gcount()));
  return bytes;
}

void write_binary_file_atomic(const std::filesystem::path& path,
                              const std::vector<std::uint8_t>& bytes,
                              bool overwrite) {
  write_bytes_atomic(path, reinterpret_cast<const char*>(bytes.data()),
                     bytes.size(), overwrite);
}

void write_text_file_atomic(const std::filesystem::path& path,
                            std::string_view text, bool overwrite) {
  write_bytes_atomic(path, text.data(), text.size(), overwrite);
}

std::string path_utf8(const std::filesystem::path& path) {
  const auto text = path.u8string();
  return std::string(text.begin(), text.end());
}

PathKey path_key(const std::filesystem::path& path) {
  const auto normalized = std::filesystem::absolute(path).lexically_normal();
  auto key = normalized.wstring();
  std::transform(key.begin(), key.end(), key.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
  return key;
}

bool same_path(const std::filesystem::path& left,
               const std::filesystem::path& right) {
  return path_key(left) == path_key(right);
}

bool is_same_or_descendant(const std::filesystem::path& path,
                           const std::filesystem::path& directory) {
  const auto candidate = path_key(path);
  auto root = path_key(directory);
  if (candidate == root) return true;
  if (!root.empty() && root.back() != std::filesystem::path::preferred_separator) {
    root.push_back(std::filesystem::path::preferred_separator);
  }
  return candidate.starts_with(root);
}

std::string lower_extension(const std::filesystem::path& path) {
  auto extension = path_utf8(path.extension());
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  return extension;
}

std::uint64_t available_memory_bytes() {
  MEMORYSTATUSEX status{};
  status.dwLength = sizeof(status);
  if (GlobalMemoryStatusEx(&status) != 0) {
    return static_cast<std::uint64_t>(status.ullAvailPhys);
  }
  return 0;
}

}  // namespace hyperdr
