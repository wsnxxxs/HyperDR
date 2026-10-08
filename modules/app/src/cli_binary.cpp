#include "cli_commands.hpp"

#include "hyperdr/foundation/parallel.hpp"

#include <bit>
#include <cmath>
#include <cstring>
#include <cstdio>

#ifdef _WIN32
#include <fcntl.h>
#include <io.h>
#endif

namespace hyperdr::app::detail {

void append_u32_le(std::vector<std::uint8_t>& bytes, std::uint32_t value) {
  bytes.push_back(static_cast<std::uint8_t>(value));
  bytes.push_back(static_cast<std::uint8_t>(value >> 8U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 16U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 24U));
}

void append_float_image(std::vector<std::uint8_t>& bytes,
                        const FloatImage& image) {
  static_assert(sizeof(float) == 4 && std::endian::native == std::endian::little);
  const auto offset = bytes.size();
  bytes.resize(offset + image.pixels.size() * sizeof(float));
  const auto row_size = static_cast<std::size_t>(image.width) * image.channels;
  parallel_for_rows(image.height, [&](std::uint32_t y) {
    const auto* row = image.pixels.data() + static_cast<std::size_t>(y) * row_size;
    if (!std::all_of(row, row + row_size, [](float value) { return std::isfinite(value); }))
      throw std::runtime_error("native preview contains a non-finite pixel");
    std::memcpy(bytes.data() + offset + static_cast<std::size_t>(y) * row_size * sizeof(float),
                row, row_size * sizeof(float));
  });
}

void set_stdout_binary() {
#ifdef _WIN32
  // The model-gain packet is a byte protocol, not text. Prevent the CRT from
  // translating its header/newlines when the CLI is piped to the panel.
  _setmode(_fileno(stdout), _O_BINARY);
#endif
}

}  // namespace hyperdr::app::detail
