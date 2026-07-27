// Exif orientation is applied to the pixels at decode, so nothing downstream
// has to know it existed. A JPEG from a phone stores landscape pixels and a
// tag saying "rotate 90"; the decoder used to discard the tag and declare
// orientation 1, so the export was on its side and its reported width and
// height were the wrong way round.

#include "hyperdr/image/orientation.hpp"

#include <cstdint>
#include <iostream>
#include <stdexcept>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

// A 3x2 image whose every pixel carries its own coordinates, so a wrong
// mapping is visible rather than merely different.
hyperdr::FloatImage coordinate_image() {
  hyperdr::FloatImage image(3, 2, 1);
  for (std::uint32_t y = 0; y < 2; ++y) {
    for (std::uint32_t x = 0; x < 3; ++x) {
      image.at(x, y, 0) = static_cast<float>(y * 10 + x);
    }
  }
  return image;
}

void check_identity_and_out_of_range() {
  const auto source = coordinate_image();
  for (const std::uint16_t orientation : {std::uint16_t{1}, std::uint16_t{0},
                                          std::uint16_t{9}, std::uint16_t{65535}}) {
    const auto out = hyperdr::apply_exif_orientation(coordinate_image(), orientation);
    require(out.width == source.width && out.height == source.height,
            "an absent or unusable tag must not change the geometry");
    require(out.pixels == source.pixels,
            "an absent or unusable tag must not move a pixel");
  }
}

void check_geometry_swaps() {
  for (const std::uint16_t orientation : {2, 3, 4}) {
    const auto out = hyperdr::apply_exif_orientation(coordinate_image(), orientation);
    require(out.width == 3 && out.height == 2, "flips preserve the axes");
  }
  for (const std::uint16_t orientation : {5, 6, 7, 8}) {
    require(hyperdr::exif_orientation_transposes(orientation),
            "5 through 8 exchange the axes");
    const auto out = hyperdr::apply_exif_orientation(coordinate_image(), orientation);
    require(out.width == 2 && out.height == 3,
            "a transposing orientation must swap width and height");
  }
}

void check_mappings() {
  // Mirror horizontal.
  const auto two = hyperdr::apply_exif_orientation(coordinate_image(), 2);
  require(two.at(0, 0, 0) == 2.0F && two.at(2, 0, 0) == 0.0F, "orientation 2");

  // Rotate 180.
  const auto three = hyperdr::apply_exif_orientation(coordinate_image(), 3);
  require(three.at(0, 0, 0) == 12.0F && three.at(2, 1, 0) == 0.0F, "orientation 3");

  // Mirror vertical.
  const auto four = hyperdr::apply_exif_orientation(coordinate_image(), 4);
  require(four.at(0, 0, 0) == 10.0F && four.at(0, 1, 0) == 0.0F, "orientation 4");

  // Rotate 90 clockwise: the source's bottom-left corner becomes the top left.
  const auto six = hyperdr::apply_exif_orientation(coordinate_image(), 6);
  require(six.at(0, 0, 0) == 10.0F, "orientation 6 top left");
  require(six.at(1, 0, 0) == 0.0F, "orientation 6 top right");
  require(six.at(0, 2, 0) == 12.0F, "orientation 6 bottom left");

  // Rotate 270 clockwise is its inverse.
  const auto eight = hyperdr::apply_exif_orientation(coordinate_image(), 8);
  require(eight.at(0, 0, 0) == 2.0F, "orientation 8 top left");
  require(eight.at(1, 2, 0) == 10.0F, "orientation 8 bottom right");
}

// Applying 6 then 8 returns the original image, which catches an off-by-one in
// either direction that a single-direction test would miss.
void check_round_trip() {
  const auto source = coordinate_image();
  const auto there = hyperdr::apply_exif_orientation(coordinate_image(), 6);
  const auto back = hyperdr::apply_exif_orientation(there, 8);
  require(back.width == source.width && back.height == source.height,
          "rotating 90 then 270 restores the geometry");
  require(back.pixels == source.pixels, "rotating 90 then 270 restores the pixels");

  // The transposes are their own inverse.
  for (const std::uint16_t orientation : {2, 3, 4, 5, 7}) {
    const auto once = hyperdr::apply_exif_orientation(coordinate_image(), orientation);
    const auto twice = hyperdr::apply_exif_orientation(once, orientation);
    require(twice.pixels == source.pixels, "these orientations are involutions");
  }
}

void check_multichannel() {
  hyperdr::FloatImage rgb(2, 1, 3);
  rgb.at(0, 0, 0) = 1.0F; rgb.at(0, 0, 1) = 2.0F; rgb.at(0, 0, 2) = 3.0F;
  rgb.at(1, 0, 0) = 4.0F; rgb.at(1, 0, 1) = 5.0F; rgb.at(1, 0, 2) = 6.0F;
  const auto mirrored = hyperdr::apply_exif_orientation(rgb, 2);
  require(mirrored.at(0, 0, 0) == 4.0F && mirrored.at(0, 0, 1) == 5.0F &&
              mirrored.at(0, 0, 2) == 6.0F,
          "channels move together");
}

}  // namespace

int main() {
  try {
    check_identity_and_out_of_range();
    check_geometry_swaps();
    check_mappings();
    check_round_trip();
    check_multichannel();
  } catch (const std::exception& e) {
    std::cerr << "orientation_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "orientation_test passed\n";
  return 0;
}
