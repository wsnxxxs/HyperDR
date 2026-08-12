#include "../src/internal/budget.hpp"

#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

}  // namespace

int main() {
  try {
    using hyperdr::codec::raw_input_budget_ok;
    using hyperdr::codec::raw_pipeline_bytes;
    require(raw_input_budget_ok(19008, 12672),
            "A7R V Pixel Shift boundary was rejected");
    require(!raw_input_budget_ok(19009, 12672),
            "one column beyond the RAW pixel limit was accepted");
    require(!raw_input_budget_ok(19008, 12673),
            "one row beyond the RAW pixel limit was accepted");
    require(!raw_input_budget_ok(0, 12672), "zero width was accepted");
    require(!raw_input_budget_ok(std::numeric_limits<std::uint64_t>::max(), 2),
            "overflowing dimensions were accepted");
    const auto full = raw_pipeline_bytes(9600, 6400, 9504, 6336);
    const auto half = raw_pipeline_bytes(9600, 6400, 4752, 3168);
    require(half > full / 4,
            "half-size incorrectly quartered the full sensor mosaic");
    require(half == 9600ULL * 6400ULL * 8ULL +
                        4752ULL * 3168ULL * 24ULL,
            "RAW memory estimate does not separate mosaic and output rasters");
    require(!raw_input_budget_ok(20000, 13000),
            "oversized sensor margins were admitted");
    std::cout << "budget tests passed\n";
  } catch (const std::exception& e) {
    std::cerr << "budget test failure: " << e.what() << '\n';
    return 1;
  }
  return 0;
}
