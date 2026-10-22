#pragma once
#include <cstddef>
namespace hyperdr {
namespace heif_limits {
inline constexpr std::size_t box_depth = 8, boxes = 65536, items = 16384, properties = 4096,
                             associations = 255, grid_tiles = 65536, icc_bytes = 4 * 1024 * 1024,
                             metadata_bytes = 16 * 1024 * 1024, nal_count = 64, nal_bytes = 65536,
                             sample_bytes = 64 * 1024 * 1024, extents = 65536;
}
}  // namespace hyperdr
