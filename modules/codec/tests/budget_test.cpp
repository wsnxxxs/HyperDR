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
    // The tiled canvas is bounded by structure, not by the raster budget: the
    // 10200x18134 story fits, its coded pictures still obey the raster geometry.
    using hyperdr::raster_geometry_ok;
    using hyperdr::tiled_canvas_ok;
    require(tiled_canvas_ok(10200, 18134) && tiled_canvas_ok(12000, 512),
            "a story or wide canvas was refused as tiled");
    require(tiled_canvas_ok(16384, 16384) && !tiled_canvas_ok(16385, 16384),
            "the tiled pixel limit moved");
    require(tiled_canvas_ok(65535, 4096) && !tiled_canvas_ok(65536, 1) &&
                !tiled_canvas_ok(1, 65536) && !tiled_canvas_ok(0, 512) &&
                !tiled_canvas_ok(std::numeric_limits<std::uint64_t>::max(), 2),
            "the tiled edge or overflow guard is wrong");
    require(raster_geometry_ok(11656, 8742) && !raster_geometry_ok(11657, 8742) &&
                !raster_geometry_ok(8742, 11657),
            "raster geometry boundary changed");
    {
      hyperdr::ExecutionScope scope({0, 15ULL * 700 * 600 - 1});
      require(!hyperdr::raster_input_budget_ok(700, 600) && raster_geometry_ok(700, 600),
              "a memory budget must limit raster input but not a coded picture's geometry");
    }
    std::cout << "budget tests passed\n";
  } catch (const std::exception& e) {
    std::cerr << "budget test failure: " << e.what() << '\n';
    return 1;
  }
  return 0;
}
