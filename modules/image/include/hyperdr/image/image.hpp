#pragma once

// The pipeline's one in-memory image type: interleaved 32-bit float samples in
// a linear working space, with the channel count carried alongside so a
// single-channel gain map and a three-channel base image share one container.

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {

// The fields stay public because every stage in the pipeline reads them and a
// getter for each would buy nothing. What they did not have was any way to
// state the one relationship that matters -- `pixels.size() == width * height *
// channels` -- so an externally assembled image with a short buffer reached
// `at()`, which indexes without a bounds check. `require_consistent()` is the
// contract, checked at the boundaries where an image arrives from outside, and
// `at()` asserts it per access in debug and test builds.
struct FloatImage {
  std::uint32_t width{};
  std::uint32_t height{};
  std::uint32_t channels{};
  std::vector<float> pixels;

  FloatImage() = default;
  FloatImage(std::uint32_t w, std::uint32_t h, std::uint32_t c)
      : width(w), height(h), channels(c), pixels(checked_size(w, h, c), 0.0F) {}

  [[nodiscard]] static std::size_t checked_size(std::uint32_t w, std::uint32_t h,
                                                std::uint32_t c) {
    if (w == 0 || h == 0 || c == 0 || c > 4) {
      throw std::invalid_argument("invalid image dimensions");
    }
    const auto max = static_cast<std::uint64_t>(std::vector<float>{}.max_size());
    const auto width = static_cast<std::uint64_t>(w);
    const auto height = static_cast<std::uint64_t>(h);
    const auto channels = static_cast<std::uint64_t>(c);
    if (width > max / height || width * height > max / channels) {
      throw std::length_error("image allocation is too large");
    }
    return static_cast<std::size_t>(width * height * channels);
  }

  // True when the dimensions and the buffer agree. An empty image (all zero,
  // no pixels) is consistent: it is what the default constructor produces.
  [[nodiscard]] bool is_consistent() const {
    if (width == 0 && height == 0 && channels == 0) return pixels.empty();
    if (width == 0 || height == 0 || channels == 0 || channels > 4) return false;
    const auto expected = static_cast<std::uint64_t>(width) * height * channels;
    return static_cast<std::uint64_t>(pixels.size()) == expected;
  }

  // Call this wherever an image crosses into the pipeline from a caller that
  // built it field by field rather than through the constructor.
  void require_consistent(const char* context = "image") const {
    if (!is_consistent()) {
      throw std::invalid_argument(std::string(context) +
                                  " has inconsistent dimensions and pixel buffer");
    }
  }

  [[nodiscard]] bool contains(std::uint32_t x, std::uint32_t y,
                              std::uint32_t c) const {
    return x < width && y < height && c < channels;
  }

  [[nodiscard]] float& at(std::uint32_t x, std::uint32_t y, std::uint32_t c) {
    assert(is_consistent() && contains(x, y, c));
    return pixels[(static_cast<std::size_t>(y) * width + x) * channels + c];
  }
  [[nodiscard]] float at(std::uint32_t x, std::uint32_t y, std::uint32_t c) const {
    assert(is_consistent() && contains(x, y, c));
    return pixels[(static_cast<std::size_t>(y) * width + x) * channels + c];
  }

  // Bounds-checked access for callers holding an image of unverified origin.
  [[nodiscard]] float checked_at(std::uint32_t x, std::uint32_t y,
                                 std::uint32_t c) const {
    require_consistent();
    if (!contains(x, y, c)) throw std::out_of_range("image sample is out of range");
    return pixels[(static_cast<std::size_t>(y) * width + x) * channels + c];
  }
};

}  // namespace hyperdr
