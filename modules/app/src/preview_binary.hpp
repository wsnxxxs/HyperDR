#pragma once
#include "hyperdr/image/image.hpp"
#include <cstdint>
#include <vector>
namespace hyperdr {
void append_u32_le(std::vector<std::uint8_t>&, std::uint32_t);
void append_float_image(std::vector<std::uint8_t>&, const FloatImage&);
}
