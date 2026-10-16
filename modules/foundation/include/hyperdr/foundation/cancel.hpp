#pragma once

#include <atomic>
#include <stdexcept>

namespace hyperdr {

class Cancelled : public std::runtime_error {
 public:
  Cancelled() : std::runtime_error("operation cancelled") {}
};

class CancelToken {
 public:
  void request() noexcept { requested_.store(true, std::memory_order_relaxed); }
  [[nodiscard]] bool requested() const noexcept {
    return requested_.load(std::memory_order_relaxed);
  }
  void check() const { if (requested()) throw Cancelled(); }
 private:
  std::atomic<bool> requested_{false};
};

// An operation's token follows its row/tile jobs. The scope restores the caller's
// token, including on exceptions and when a pool thread runs the next request.
inline thread_local const CancelToken* current_cancel_token = nullptr;
class CancelScope {
 public:
  explicit CancelScope(const CancelToken* token) noexcept
      : previous_(current_cancel_token) { current_cancel_token = token; }
  ~CancelScope() { current_cancel_token = previous_; }
  CancelScope(const CancelScope&) = delete;
  CancelScope& operator=(const CancelScope&) = delete;
 private:
  const CancelToken* previous_;
};
inline void check_cancelled() {
  if (current_cancel_token) current_cancel_token->check();
}

}  // namespace hyperdr
