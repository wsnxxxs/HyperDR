#include "hyperdr/foundation/parallel.hpp"

#include <chrono>
#include <future>
#include <iostream>

int main() {
  try {
    hyperdr::CancelToken token;
    std::promise<void> started;
    std::atomic<bool> first{true};
    auto task = std::async(std::launch::async, [&] {
      hyperdr::CancelScope scope(&token);
      try {
        hyperdr::parallel_for_rows(1000000, [&](auto) {
          if (first.exchange(false)) started.set_value();
          std::this_thread::sleep_for(std::chrono::milliseconds(1));
        });
      } catch (const hyperdr::Cancelled&) { return true; }
      return false;
    });
    started.get_future().wait();
    const auto begin = std::chrono::steady_clock::now();
    token.request();
    if (!task.get()) throw std::runtime_error("row cancellation was lost");
    const auto elapsed = std::chrono::steady_clock::now() - begin;
    if (elapsed > std::chrono::milliseconds(200)) throw std::runtime_error("row cancellation exceeded 200 ms");
    // Pool workers must restore their token before accepting another operation.
    std::atomic<unsigned> rows{};
    hyperdr::parallel_for_rows(1000, [&](auto) { ++rows; });
    if (rows != 1000 || hyperdr::current_cancel_token) throw std::runtime_error("cancel scope leaked");
    std::cout << "cancel latency: " << std::chrono::duration<double, std::milli>(elapsed).count() << " ms\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << e.what() << '\n';
    return 1;
  }
}
