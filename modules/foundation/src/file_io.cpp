#include "hyperdr/foundation/file_io.hpp"
#include "file_io_platform.hpp"

#include <algorithm>
#include <cctype>
#include <cwctype>
#include <fstream>
#include <stdexcept>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#endif

namespace hyperdr {

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
  detail::write_bytes_atomic(path, reinterpret_cast<const char*>(bytes.data()),
                             bytes.size(), overwrite);
}

void write_text_file_atomic(const std::filesystem::path& path,
                            std::string_view text, bool overwrite) {
  detail::write_bytes_atomic(path, text.data(), text.size(), overwrite);
}

std::string path_utf8(const std::filesystem::path& path) {
  const auto text = path.u8string();
  return std::string(text.begin(), text.end());
}

std::filesystem::path path_from_utf8(std::string_view text) {
  return std::filesystem::path(std::u8string_view(
      reinterpret_cast<const char8_t*>(text.data()), text.size()));
}

PathKey path_key(const std::filesystem::path& path) {
  const auto normalized = std::filesystem::absolute(path).lexically_normal();
  auto key = normalized.native();
#ifdef _WIN32
  std::transform(key.begin(), key.end(), key.begin(),
                 [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
#elif defined(__APPLE__)
  // Apple filesystems commonly fold Unicode case and canonical equivalents.
  const auto text = CFStringCreateWithBytes(
      kCFAllocatorDefault, reinterpret_cast<const UInt8*>(key.data()),
      static_cast<CFIndex>(key.size()), kCFStringEncodingUTF8, false);
  if (text == nullptr) throw std::runtime_error("path is not valid UTF-8");
  const auto folded = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, text);
  CFRelease(text);
  CFStringNormalize(folded, kCFStringNormalizationFormD);
  CFStringFold(folded, kCFCompareCaseInsensitive, nullptr);
  key.resize(static_cast<std::size_t>(CFStringGetMaximumSizeForEncoding(
                 CFStringGetLength(folded), kCFStringEncodingUTF8)) + 1);
  CFStringGetCString(folded, key.data(), static_cast<CFIndex>(key.size()),
                     kCFStringEncodingUTF8);
  CFRelease(folded);
  key.resize(std::char_traits<char>::length(key.c_str()));
#endif
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

}  // namespace hyperdr
