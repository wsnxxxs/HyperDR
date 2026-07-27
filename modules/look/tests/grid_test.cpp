// The gain grid's sampler is a public entry point that used to trust its
// arguments completely: it took a buffer and a width and height that nothing
// compared against it, and it computed cell coordinates in single-precision
// floats that stop being exact long before the image sizes it accepts do.

#include "hyperdr/look/grid.hpp"

#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

template <class Fn>
bool throws_invalid_argument(Fn&& fn) {
  try {
    fn();
  } catch (const std::invalid_argument&) {
    return true;
  } catch (...) {
    return false;
  }
  return false;
}

// The reported reproduction: an empty grid described as 1x1 read past its end.
void check_short_buffer_is_rejected() {
  require(throws_invalid_argument([] {
            static_cast<void>(
                hyperdr::sample_grid_bilinear({}, 1, 1, 1, 1, 0, 0));
          }),
          "an empty grid must be rejected, not read");

  const std::vector<float> eight(8, 1.0F);
  require(throws_invalid_argument([&] {
            static_cast<void>(
                hyperdr::sample_grid_bilinear(eight, 3, 3, 9, 9, 4, 4));
          }),
          "a buffer shorter than width x height must be rejected");
  require(throws_invalid_argument(
              [&] { static_cast<void>(hyperdr::GridView(eight, 3, 3)); }),
          "the view constructor is where the precondition is enforced");
  require(throws_invalid_argument(
              [&] { static_cast<void>(hyperdr::GridView(eight, 0, 4)); }),
          "a zero grid extent must be rejected");
}

void check_zero_image_extent_is_rejected() {
  const std::vector<float> grid(4, 0.5F);
  require(throws_invalid_argument([&] {
            static_cast<void>(
                hyperdr::sample_grid_bilinear(grid, 2, 2, 0, 2, 0, 0));
          }),
          "a zero image extent must be rejected rather than divided by");
}

void check_sampling_is_exact_at_cell_centres() {
  // 2x2 grid over a 4x4 image: cell centres land on pixels 0 and 2.
  const std::vector<float> grid{0.0F, 1.0F, 2.0F, 3.0F};
  const hyperdr::GridView view(grid, 2, 2);
  require(hyperdr::sample_grid_bilinear(view, 4, 4, 0, 0) == 0.0F, "top left");
  require(hyperdr::sample_grid_bilinear(view, 4, 4, 3, 0) == 1.0F, "top right");
  require(hyperdr::sample_grid_bilinear(view, 4, 4, 0, 3) == 2.0F, "bottom left");
  require(hyperdr::sample_grid_bilinear(view, 4, 4, 3, 3) == 3.0F, "bottom right");
}

// Coordinates for a very wide image. `(x + 0.5) * grid_width` reaches 4.6e9
// here, past a float's 24-bit mantissa, so the index the caller floors was
// computed from a rounded product. Every sampled position must still fall in
// the grid, and the mapping must stay monotonic.
void check_large_image_coordinates() {
  constexpr std::uint32_t kImageWidth = 1'500'000;
  constexpr std::uint32_t kGridWidth = 3068;
  std::uint32_t previous = 0;
  for (std::uint32_t x = 0; x < kImageWidth; x += 977) {
    const auto c =
        hyperdr::bilinear_grid_coordinates(kGridWidth, 4, kImageWidth, 4, x, 0);
    require(c.x0 < kGridWidth && c.x1 < kGridWidth, "index stays inside the grid");
    require(c.x0 >= previous, "cell index is monotonic in x");
    require(c.tx >= 0.0F && c.tx <= 1.0F, "interpolation weight stays normalised");
    previous = c.x0;
  }
  const auto last = hyperdr::bilinear_grid_coordinates(
      kGridWidth, 4, kImageWidth, 4, kImageWidth - 1, 0);
  require(last.x0 == kGridWidth - 1,
          "the final pixel maps to the final cell, not back to the start");
}

}  // namespace

int main() {
  try {
    check_short_buffer_is_rejected();
    check_zero_image_extent_is_rejected();
    check_sampling_is_exact_at_cell_centres();
    check_large_image_coordinates();
  } catch (const std::exception& e) {
    std::cerr << "grid_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "grid_test passed\n";
  return 0;
}
