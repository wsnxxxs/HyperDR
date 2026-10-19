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
    using hyperdr::codec::raster_budget_ok;
    require(raster_budget_ok(4500, 8000),
            "supported 4500x8000 raster was rejected");
    require(raster_budget_ok(11656, 8742),
            "configured raster boundary was rejected");
    require(raster_budget_ok(8742, 11656),
            "rotated configured raster boundary was rejected");
    require(!raster_budget_ok(12000, 8000),
            "raster beyond the configured width was accepted");
    require(!raster_budget_ok(9000, 9000),
            "raster beyond the configured height was accepted");
    const auto preview = hyperdr::codec::raster_decode_plan(513, 257, 257);
    require(preview.width == 257 && preview.height == 129 && !preview.budget_limited,
            "odd raster preview fell below its requested decode floor");
    const auto reduced = hyperdr::codec::raster_decode_plan(12000, 8000, 0);
    require(reduced.width == 6000 && reduced.height == 4000 && reduced.budget_limited,
            "budget-driven reduction was confused with a preview request");
    require(raw_input_budget_ok(19008, 12672),
            "A7R V Pixel Shift boundary was rejected");
    require(!raw_input_budget_ok(19009, 12672),
            "one column beyond the RAW pixel limit was accepted");
    require(!raw_input_budget_ok(19008, 12673),
            "one row beyond the RAW pixel limit was accepted");
    require(!raw_input_budget_ok(0, 12672), "zero width was accepted");
    require(!raw_input_budget_ok(std::numeric_limits<std::uint64_t>::max(), 2),
            "overflowing dimensions were accepted");
    require(!raw_input_budget_ok(20000, 13000),
            "oversized sensor margins were admitted");
    std::cout << "budget tests passed\n";
  } catch (const std::exception& e) {
    std::cerr << "budget test failure: " << e.what() << '\n';
    return 1;
  }
  return 0;
}
