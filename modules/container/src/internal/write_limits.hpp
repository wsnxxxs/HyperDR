#pragma once
#include <cstddef>
#include "hyperdr/container/heif_limits.hpp"
#include <cstdint>
#include <limits>
#include <stdexcept>
namespace hyperdr::container {
inline constexpr std::uint64_t kHeifFileLimit=std::numeric_limits<std::uint32_t>::max();
// Item budget shared by the writers and the tmap/inspect readers: 4096 coded
// tiles plus their grid, tmap, Exif and XMP items must stay readable.
inline constexpr std::size_t kHeifMaxTiles=4096;
inline constexpr std::size_t kHeifMaxItems=heif_limits::items;
static_assert(kHeifMaxTiles+2+1+2<=kHeifMaxItems);
inline std::uint64_t bounded_heif_add(std::uint64_t size,std::uint64_t amount,
    std::uint64_t limit=kHeifFileLimit) {
  if(size>limit || amount>limit-size)throw std::invalid_argument("HEIF length/offset exceeds limit");
  return size+amount;
}
} // namespace hyperdr::container
