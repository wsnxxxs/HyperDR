#pragma once
#include "hyperdr/container/iso_gain_map.hpp"
#include "hyperdr/image/image.hpp"
#include <vector>
namespace hyperdr::codec {
struct GainMapRead { FloatImage pixels; GainMapMetadata metadata; };
[[nodiscard]] GainMapRead read_gain_map_jpeg_imageio(const std::vector<std::uint8_t>& bytes);
}
