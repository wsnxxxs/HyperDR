// The presentation frame is the one stage that adds pixels the renderer never
// saw. These cases pin what it promises: an integer layout that is the same
// for every caller, frame pixels that depend only on the spec (so SDR and HDR
// receive identical frames and the gain there is exactly zero), and a photo
// that is copied rather than resampled.

#include "hyperdr/image/frame.hpp"
#include "hyperdr/image/transfer.hpp"

#include <cmath>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

using hyperdr::FloatImage;
using hyperdr::FrameLayout;
using hyperdr::FrameRect;
using hyperdr::FrameSpec;

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void near(float actual, float expected, float tolerance, const char* message) {
  if (!(std::abs(actual - expected) <= tolerance)) {
    std::cerr << message << ": " << actual << " expected " << expected << '\n';
    throw std::runtime_error(message);
  }
}

template <class Function>
void rejects(Function function, const char* message) {
  try {
    function();
  } catch (const std::invalid_argument&) {
    return;
  }
  throw std::runtime_error(message);
}

FrameSpec spec_from(std::string_view text) {
  return hyperdr::parse_frame_spec(hyperdr::json::parse(text));
}

FloatImage ramp(std::uint32_t width, std::uint32_t height, float scale) {
  FloatImage image(width, height, 3);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      image.at(x, y, 0) = scale * static_cast<float>(x + 1) / static_cast<float>(width);
      image.at(x, y, 1) = scale * static_cast<float>(y + 1) / static_cast<float>(height);
      image.at(x, y, 2) = scale * 0.5F;
    }
  }
  return image;
}

bool inside(const FrameRect& rect, std::uint32_t x, std::uint32_t y) {
  return x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height;
}

void check_parse_and_canonical_text() {
  const auto spec = spec_from(R"({
    "schema": "hyperdr.frame/v1", "background": "#F4F2EC",
    "margins": {"top": 0.05, "right": 0.04, "bottom": 0.06, "left": 0.04},
    "caption": 0.1, "reference": "long",
    "aspect": {"width": 4, "height": 5, "topShare": 0.25},
    "shadow": {"opacity": 0.12, "blur": 0.01, "offset": 0.004}})");
  near(spec.background[0], 0xF4 / 255.0F, 1e-6F, "background red");
  near(spec.background[2], 0xEC / 255.0F, 1e-6F, "background blue");
  near(spec.right, 0.04F, 1e-7F, "right margin");
  require(spec.reference == hyperdr::FrameReference::kLongEdge, "reference edge");
  require(spec.aspect_width == 4 && spec.aspect_height == 5, "aspect");
  near(spec.shadow_blur, 0.01F, 1e-7F, "shadow blur");

  // Canonical text is a fixed point: it is what the fingerprint hashes.
  const auto text = hyperdr::frame_spec_json(spec);
  require(hyperdr::frame_spec_json(spec_from(text)) == text,
          "canonical frame text must round-trip unchanged");

  const auto uniform = spec_from(R"({"margins": 0.03})");
  require(uniform.top == uniform.right && uniform.right == uniform.bottom &&
              uniform.bottom == uniform.left && std::abs(uniform.left - 0.03F) < 1e-7F,
          "a single margin number applies to every side");

  const auto overlay = hyperdr::parse_frame_spec(
      hyperdr::json::parse(R"({"overlay": "caption.png"})"), "/tmp/frames");
  require(overlay.overlay == std::filesystem::path("/tmp/frames/caption.png"),
          "a relative overlay resolves against the spec's directory");
}

void check_parse_rejections() {
  rejects([] { (void)spec_from(R"({"margin": 0.1})"); }, "an unknown member must be rejected");
  rejects([] { (void)spec_from(R"({"background": "#FFF"})"); }, "short hex must be rejected");
  rejects([] { (void)spec_from(R"({"background": "#GG0000"})"); }, "non-hex must be rejected");
  rejects([] { (void)spec_from(R"({"margins": 0.6})"); }, "a margin over half the edge must be rejected");
  rejects([] { (void)spec_from(R"({"caption": -0.1})"); }, "a negative caption must be rejected");
  rejects([] { (void)spec_from(R"({"aspect": {"width": 1, "height": 9}})"); },
          "an aspect beyond 1:4 must be rejected");
  rejects([] { (void)spec_from(R"({"shadow": {"opacity": 1.5}})"); },
          "shadow opacity above one must be rejected");
  rejects([] { (void)spec_from(R"({"schema": "hyperdr.frame/v2"})"); },
          "another schema version must be rejected");
  rejects([] { (void)spec_from(R"({"reference": "diagonal"})"); }, "unknown reference edge");
}

void check_natural_layout() {
  const auto spec = spec_from(R"({"margins": 0.05, "caption": 0.1})");
  const auto layout = hyperdr::layout_frame(spec, 3000, 2000);
  // 5% and 10% of the 2000-pixel short edge.
  require(layout.width == 3200 && layout.height == 2400, "natural canvas size");
  require(layout.photo == FrameRect{100, 100, 3000, 2000}, "photo placement");
  require(layout.caption == FrameRect{0, 2100, 3200, 300}, "caption band below the photo");
  require(layout.reference_edge == 2000, "reference edge");

  // A spec without a mat keeps the photo in place; an odd photo still gets
  // an even canvas, with the extra column on the right and row below.
  const auto none = hyperdr::layout_frame(FrameSpec{}, 31, 17);
  require(none.width == 32 && none.height == 18 && none.photo == FrameRect{0, 0, 31, 17} &&
              none.caption == FrameRect{0, 17, 32, 1},
          "an empty spec pads an odd photo to an even canvas");
  const auto even = hyperdr::layout_frame(FrameSpec{}, 32, 18);
  require(even.width == 32 && even.height == 18 && even.caption.height == 0,
          "an empty spec leaves an even photo's canvas at the photo size");
}

void check_even_mats() {
  // 3.33% of 1001 is 33.4 pixels: rounded to the nearest even count.
  const auto spec = spec_from(R"({"margins": 0.0333, "caption": 0.0711})");
  const auto layout = hyperdr::layout_frame(spec, 1001, 1501);
  require(layout.photo.x == 34 && layout.photo.y == 34, "mats round to even pixels");
  require(layout.width == 1001 + 68 + 1, "an odd canvas width gains a column on the right");
  require(layout.width - layout.photo.x - layout.photo.width == 35, "the right mat takes it");
  require(layout.caption.height == 34 + 72 + 1, "bottom mat plus caption band, plus a row for an even canvas");
}

void check_fixed_aspect() {
  // A portrait print on a 9:16 story canvas is too wide for it: the canvas
  // grows downward, a quarter of the added height above the photo.
  const auto story = spec_from(R"({"margins": 0.06, "caption": 0.12,
      "aspect": {"width": 9, "height": 16, "topShare": 0.25}})");
  const auto tall = hyperdr::layout_frame(story, 1000, 1500);
  require(tall.width == 1120, "story width is the natural width");
  require(tall.height == 1992, "story height is width * 16 / 9, rounded up to even");
  const auto natural_height = 60U + 1500U + 60U + 120U;
  const auto added = 1991U - natural_height;  // before the row that makes the canvas even
  require(tall.photo.y == 60 + 2 * static_cast<std::uint32_t>(std::lround(added * 0.25 / 2)),
          "a quarter of the added height goes above the photo, in even pixels");
  require(tall.photo.y % 2 == 0, "photo origin stays even");
  require(tall.caption.y + tall.caption.height == tall.height, "caption band reaches the bottom");

  // A landscape print on a square canvas grows in height, split evenly.
  const auto square = spec_from(R"({"margins": 0.05, "aspect": {"width": 1, "height": 1}})");
  const auto landscape = hyperdr::layout_frame(square, 1500, 1000);
  require(landscape.width == 1600 && landscape.height == 1600, "square landscape canvas");
  require(landscape.photo.y == 300, "half the added height goes above the photo");

  // A portrait print on it grows sideways; the left mat stays even and the
  // odd pixel of the added width goes to the right.
  const auto portrait = hyperdr::layout_frame(square, 1001, 1500);
  require(portrait.width == 1600 && portrait.height == 1600, "square portrait canvas");
  require(portrait.photo.x == 300, "added width is split between the sides");
  require(portrait.width - portrait.photo.x - portrait.photo.width == 299, "odd remainder on the right");
}

}  // namespace

int main() {
  try {
    check_parse_and_canonical_text();
    check_parse_rejections();
    check_natural_layout();
    check_even_mats();
    check_fixed_aspect();
  } catch (const std::exception& error) {
    std::cerr << "frame_test failed: " << error.what() << '\n';
    return 1;
  }
  std::cout << "frame_test passed\n";
  return 0;
}
