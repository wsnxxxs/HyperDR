#pragma once

// Row-parallel helper backed by a small process-wide thread pool. Used
// instead of std::execution::par so the implementation owns its scheduling
// and has no parallel-backend dependency. Each row must be independent; any
// reduction is done by writing per-row results into
// caller-owned buffers and combining afterwards, which keeps output
// bit-for-bit deterministic regardless of worker count.
//
// The pool's worker threads are created once (on first use) and live for the
// rest of the process, rather than being spawned and joined on every call.
// A single conversion calls parallel_for_rows a dozen-plus times across
// gain_map/guided_filter/photographic_look/heif_encoder/raster_decoder, so
// reusing threads avoids repeated OS thread creation within each image.

#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <exception>
#include <functional>
#include <latch>
#include <memory>
#include <mutex>
#include <system_error>
#include <thread>
#include <vector>

namespace hyperdr {

class ThreadPool {
 public:
  static ThreadPool& shared() {
    static ThreadPool pool;
    return pool;
  }

  ThreadPool(const ThreadPool&) = delete;
  ThreadPool& operator=(const ThreadPool&) = delete;

  // Runs fn(y) for every y in [0, height), distributing rows across this
  // pool's worker threads plus the calling thread, and blocks until every
  // row has completed. fn must be safe to invoke concurrently for distinct
  // row indices; it may not be safe to invoke concurrently for the *same*
  // index, which this never does.
  template <class Fn>
  void for_rows(std::uint32_t height, Fn&& fn) {
    if (height == 0) return;
    if (worker_count_ == 0 || height < 64) {
      for (std::uint32_t y = 0; y < height; ++y) fn(y);
      return;
    }

    // Never dispatch more helper jobs than there are rows for them to take.
    // The count is fixed before the shared state exists so completion can be
    // tracked by a latch, whose count_down/wait pair carries the release-acquire
    // edge itself. The previous condition_variable signalled without holding the
    // waiter's mutex while the predicate (an atomic counter) was also updated
    // outside it, which permits a lost wakeup: the last worker could notify in
    // the window between the waiter evaluating the predicate and blocking, and
    // the whole conversion would then hang forever.
    const unsigned jobs = std::min<unsigned>(worker_count_, height - 1);

    struct State {
      State(std::uint32_t row_count, unsigned job_count, Fn&& callback)
          : height(row_count),
            fn(std::forward<Fn>(callback)),
            done(static_cast<std::ptrdiff_t>(job_count)) {}

      const std::uint32_t height;
      std::decay_t<Fn> fn;
      std::atomic<std::uint32_t> next{0};
      std::latch done;
      std::mutex exception_mutex;
      std::exception_ptr exception;
    };
    auto state = std::make_shared<State>(height, jobs, std::forward<Fn>(fn));

    const auto run_chunk = [state] {
      for (;;) {
        const std::uint32_t y = state->next.fetch_add(1, std::memory_order_relaxed);
        if (y >= state->height) break;
        try {
          state->fn(y);
        } catch (...) {
          std::lock_guard<std::mutex> lock(state->exception_mutex);
          if (!state->exception) state->exception = std::current_exception();
          break;
        }
      }
    };

    if (jobs > 0) {
      std::function<void()> job = [state, run_chunk] {
        run_chunk();
        state->done.count_down();
      };
      {
        std::lock_guard<std::mutex> lock(queue_mutex_);
        for (unsigned i = 0; i < jobs; ++i) queue_.push_back(job);
      }
      queue_cv_.notify_all();
    }

    run_chunk();  // The calling thread helps too instead of sitting idle.

    state->done.wait();  // Returns immediately when the latch was created at 0.
    if (state->exception) std::rethrow_exception(state->exception);
  }

 private:
  ThreadPool() {
    unsigned hardware = std::thread::hardware_concurrency();
    if (hardware == 0) hardware = 1;
    const unsigned wanted = hardware > 1 ? hardware - 1 : 0;
    threads_.reserve(wanted);
    for (unsigned i = 0; i < wanted; ++i) {
      // A thread or address-space limit must not leave a partly built pool: the
      // destructor of a constructor that threw never runs, and unwinding the
      // member vector over joinable threads calls std::terminate. Whatever was
      // created still forms a working pool, and zero workers is the documented
      // serial path, so a failure degrades instead of aborting the process.
      try {
        threads_.emplace_back([this] { worker_loop(); });
      } catch (const std::system_error&) {
        break;
      }
    }
    worker_count_ = static_cast<unsigned>(threads_.size());
  }

  ~ThreadPool() {
    {
      std::lock_guard<std::mutex> lock(queue_mutex_);
      stop_ = true;
    }
    queue_cv_.notify_all();
    for (auto& thread : threads_) {
      if (thread.joinable()) thread.join();
    }
  }

  void worker_loop() {
    for (;;) {
      std::function<void()> job;
      {
        std::unique_lock<std::mutex> lock(queue_mutex_);
        queue_cv_.wait(lock, [this] { return stop_ || !queue_.empty(); });
        if (queue_.empty()) {
          if (stop_) return;
          continue;
        }
        job = std::move(queue_.front());
        queue_.pop_front();
      }
      job();
    }
  }

  unsigned worker_count_ = 0;
  std::vector<std::thread> threads_;
  std::mutex queue_mutex_;
  std::condition_variable queue_cv_;
  std::deque<std::function<void()>> queue_;
  bool stop_ = false;
};

template <class Fn>
void parallel_for_rows(std::uint32_t height, Fn&& fn) {
  ThreadPool::shared().for_rows(height, std::forward<Fn>(fn));
}

}  // namespace hyperdr
