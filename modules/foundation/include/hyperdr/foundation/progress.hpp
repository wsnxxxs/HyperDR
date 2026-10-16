#pragma once

#include <cstdint>
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
