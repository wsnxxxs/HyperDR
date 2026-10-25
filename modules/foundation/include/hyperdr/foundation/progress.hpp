#pragma once

#include <cstdint>
#include <functional>
#include <string_view>

namespace hyperdr {

struct ProgressEvent {
  std::string_view phase;
  std::string_view path;
  double fraction{};
  // CLI presentation, retained verbatim for the command-line adapter.
  std::string_view text;
};
class ProgressSink {
 public:
  virtual ~ProgressSink() = default;
  // Called synchronously on the operation's calling thread. Views last only
  // through this call. Sinks must not throw or reenter the same preview session.
  virtual void on_progress(const ProgressEvent& event) = 0;
};

// How many of a row writer's independent units are done: AVIF cells encoded,
// then verified. Reported on the package thread only, between units; a writer
// without such units reports nothing. The callback must not throw.
enum class PackagePhase : std::uint32_t { EncodeCells = 1, VerifyCells = 2 };
using PackageProgress = std::function<void(PackagePhase, std::uint32_t done, std::uint32_t total)>;
inline thread_local const PackageProgress* current_package_progress = nullptr;
class PackageProgressScope {
 public:
  explicit PackageProgressScope(const PackageProgress* progress) noexcept
      : previous_(current_package_progress) { current_package_progress = progress; }
  ~PackageProgressScope() { current_package_progress = previous_; }
  PackageProgressScope(const PackageProgressScope&) = delete;
  PackageProgressScope& operator=(const PackageProgressScope&) = delete;
 private:
  const PackageProgress* previous_;
};
inline void report_package_progress(PackagePhase phase, std::uint32_t done, std::uint32_t total) {
  if (current_package_progress && *current_package_progress) (*current_package_progress)(phase, done, total);
}

struct ExecutionConfig {
  unsigned heic_tile_workers{};  // Zero selects the automatic concurrency.
  std::uint64_t memory_budget_bytes{};  // Zero uses the codec's normal budget.
};
inline thread_local ExecutionConfig current_execution_config;
class ExecutionScope {
 public:
  explicit ExecutionScope(ExecutionConfig config) noexcept
      : previous_(current_execution_config) { current_execution_config = config; }
  ~ExecutionScope() { current_execution_config = previous_; }
  ExecutionScope(const ExecutionScope&) = delete;
  ExecutionScope& operator=(const ExecutionScope&) = delete;
 private:
  ExecutionConfig previous_;
};

}  // namespace hyperdr
