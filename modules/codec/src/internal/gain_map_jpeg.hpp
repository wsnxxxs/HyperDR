#pragma once
#include "hyperdr/codec/gain_map_jpeg.hpp"
namespace hyperdr::codec::testing {
// Per-thread seam immediately around the non-interruptible auxiliary read.
void set_imageio_gain_map_hook(void (*hook)(bool before) noexcept);
}
