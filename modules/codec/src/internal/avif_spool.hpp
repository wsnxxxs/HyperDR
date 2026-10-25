#pragma once

#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <filesystem>
#include <fcntl.h>
#include <memory>
#include <span>
#include <stdexcept>
#include <string>
#include <system_error>
#include <unistd.h>
#include <uuid/uuid.h>

namespace hyperdr::internal {
// Disk-backed, never a named pixel file. A failed unlink must close/fail before
// fdopen or any write. Adjacent to the staging output for the host's disk policy.
class AvifSpool {
  std::unique_ptr<FILE, decltype(&fclose)> file{nullptr, &fclose};
  static void require(bool ok, const char* message) {
    if (!ok) throw std::runtime_error(message);
  }
 public:
  // Syscall seams are internal and used only by the source regression tests.
  explicit AvifSpool(const std::filesystem::path& destination,
                     int (*create)(const char*, int, mode_t) = [](const char* name, int flags, mode_t mode) { return ::open(name, flags, mode); },
                     int (*remove)(const char*) = &::unlink,
                     int (*configure)(int, int, int) = [](int fd, int command, int value) { return ::fcntl(fd, command, value); }) {
    // O_CLOEXEC must be atomic with creation: mkstemp followed by F_SETFD
    // leaves a fork/exec inheritance window in the multithreaded host.
    int fd = -1;
    std::string name;
    for (unsigned attempt = 0; attempt < 8; ++attempt) {
      uuid_t uuid; char text[37]; ::uuid_generate_random(uuid); ::uuid_unparse_lower(uuid, text);
      name = (destination.parent_path() / (std::string(".hyperdr-avif-") + text)).string();
      fd = create(name.c_str(), O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC, 0600);
      if (fd >= 0) break;
      if (errno != EEXIST) throw std::system_error(errno, std::generic_category(), "create AVIF spool");
    }
    if (fd < 0) throw std::system_error(EEXIST, std::generic_category(), "create AVIF spool (collision limit)");
    const auto fail = [&](const char* operation) {
      const int error = errno; ::close(fd);
      throw std::system_error(error, std::generic_category(), operation);
    };
    if (remove(name.c_str()) != 0) fail("unlink AVIF spool");
    if (configure(fd, F_NOCACHE, 1) != 0) fail("disable AVIF spool caching");
    FILE* f = ::fdopen(fd, "w+b");
    if (!f) fail("open AVIF spool");
    file.reset(f);
  }
  void seek(std::uint64_t offset) {
    // Seeking also flushes pending stdio writes: preserve disk-full/quota errno.
    if (fseeko(file.get(), off_t(offset), SEEK_SET) != 0)
      throw std::system_error(errno ? errno : EIO, std::generic_category(), "seek AVIF spool");
  }
  void write(std::span<const std::uint8_t> b) {
    if (fwrite(b.data(), 1, b.size(), file.get()) != b.size())
      throw std::system_error(errno ? errno : EIO, std::generic_category(), "write AVIF spool");
  }
  void read(std::span<std::uint8_t> b) { require(fread(b.data(), 1, b.size(), file.get()) == b.size(), "read AVIF spool failed"); }
};
} // namespace hyperdr::internal
