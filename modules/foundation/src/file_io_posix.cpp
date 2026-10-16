#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif

#include "hyperdr/foundation/file_io.hpp"
#include "file_io_platform.hpp"

#include <atomic>
#include <cerrno>
#include <cstdio>
#include <fcntl.h>
#include <fstream>
#include <stdexcept>
#include <string>
#include <system_error>
#include <unistd.h>

#ifdef __linux__
#include <linux/fs.h>
#endif

#ifdef __APPLE__
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#else
#include <mach/mach.h>
#endif
#endif

namespace hyperdr {
namespace {

void check_io(bool failed, const char* action) {
  if (failed) throw std::system_error(errno, std::generic_category(), action);
}

void publish_no_replace(const std::filesystem::path& temporary,
                         const std::filesystem::path& path) {
#ifdef __APPLE__
  const int result = renameatx_np(AT_FDCWD, temporary.c_str(), AT_FDCWD,
                                  path.c_str(), RENAME_EXCL);
#else
  const int result = renameat2(AT_FDCWD, temporary.c_str(), AT_FDCWD,
                               path.c_str(), RENAME_NOREPLACE);
#endif
  if (result == 0) return;
  if (errno != ENOTSUP && errno != EOPNOTSUPP && errno != EINVAL &&
      errno != ENOSYS) {
    check_io(true, "cannot atomically publish output");
  }

  if (link(temporary.c_str(), path.c_str()) == 0) {
    check_io(unlink(temporary.c_str()) != 0, "cannot remove temporary output");
    return;
  }
  if (errno != ENOTSUP && errno != EOPNOTSUPP && errno != EINVAL &&
      errno != ENOSYS && errno != EPERM) {
    check_io(true, "cannot atomically publish output");
  }

  // Publish complete bytes and refuse observed existing paths; cross-process
  // creation can race this check (batch output collisions are rejected earlier).
  if (std::filesystem::exists(std::filesystem::symlink_status(path))) {
    throw std::runtime_error("output exists: " + path_utf8(path));
  }
  check_io(rename(temporary.c_str(), path.c_str()) != 0,
           "cannot atomically publish output");
}

}  // namespace

namespace detail {

void write_bytes_atomic(const std::filesystem::path& path, const char* data,
                        std::size_t size, bool overwrite) {
  if (!overwrite && std::filesystem::exists(path)) {
    throw std::runtime_error("output exists: " + path_utf8(path));
  }
  const auto directory = path.parent_path().empty() ? std::filesystem::path(".")
                                                   : path.parent_path();
  std::filesystem::create_directories(directory);
  static std::atomic_uint64_t sequence{0};
  std::filesystem::path temporary;
  int file = -1;
  do {
    temporary = path;
    temporary += ".tmp." + std::to_string(getpid()) + "." +
                 std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
    file = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
  } while (file < 0 && errno == EEXIST);
  check_io(file < 0, "cannot create temporary output");

  try {
    std::size_t offset = 0;
    while (offset < size) {
      const auto written = write(file, data + offset, size - offset);
      if (written < 0 && errno == EINTR) continue;
      check_io(written < 0, "cannot write temporary output");
      offset += static_cast<std::size_t>(written);
    }
    check_io(fsync(file) != 0, "cannot flush temporary output");
    const auto closed = close(file);
    file = -1;
    check_io(closed != 0, "cannot close temporary output");
    if (overwrite) {
      check_io(rename(temporary.c_str(), path.c_str()) != 0,
               "cannot atomically publish output");
    } else {
      publish_no_replace(temporary, path);
    }
    const int parent = open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    check_io(parent < 0, "cannot open output directory");
    const auto synced = fsync(parent);
    const auto error = errno;
    close(parent);
    errno = error;
    check_io(synced != 0, "cannot flush output directory");
  } catch (...) {
    if (file >= 0) close(file);
    unlink(temporary.c_str());
    throw;
  }
}

}  // namespace detail

std::uint64_t available_memory_bytes() {
#ifdef __APPLE__
#if TARGET_OS_IPHONE
  return static_cast<std::uint64_t>(os_proc_available_memory());
#else
  vm_statistics64_data_t status{};
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  const auto host = mach_host_self();
  vm_size_t page_size = 0;
  const bool ok = host_page_size(host, &page_size) == KERN_SUCCESS &&
      host_statistics64(host, HOST_VM_INFO64,
                        reinterpret_cast<host_info64_t>(&status), &count) == KERN_SUCCESS;
  mach_port_deallocate(mach_task_self(), host);
  if (ok) {
    return (static_cast<std::uint64_t>(status.free_count) + status.inactive_count) *
           page_size;
  }
#endif
#else
  std::ifstream input("/proc/meminfo");
  std::string key;
  std::uint64_t kilobytes = 0;
  std::string unit;
  while (input >> key >> kilobytes >> unit) {
    if (key == "MemAvailable:") return kilobytes * 1024;
  }
#endif
  return 0;
}

}  // namespace hyperdr
