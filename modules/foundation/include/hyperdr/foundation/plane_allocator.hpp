#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <memory>
#include <new>
#include <sys/mman.h>
#include <vector>

namespace hyperdr {
// macOS's large malloc cache retains freed float canvases in the process
// footprint. Large image planes have deterministic stage lifetimes: map them
// directly so releasing a rendition also releases its pages. Small buffers
// stay with the normal allocator. Sanitizers retain their normal red zones.
template<class T> struct PlaneAllocator {
  using value_type = T;
  static_assert(alignof(T) <= alignof(std::max_align_t));
  using is_always_equal = std::true_type;
  PlaneAllocator() noexcept = default;
  template<class U> PlaneAllocator(const PlaneAllocator<U>&) noexcept {}
  [[nodiscard]] T* allocate(std::size_t count) {
    if (count > std::numeric_limits<std::size_t>::max()/sizeof(T)) throw std::bad_array_new_length();
    if (!mapped(count)) return std::allocator<T>{}.allocate(count);
    void* p=mmap(nullptr,count*sizeof(T),PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if (p==MAP_FAILED) throw std::bad_alloc();
    return static_cast<T*>(p);
  }
  void deallocate(T* p,std::size_t count) noexcept {
    if (mapped(count)) munmap(p,count*sizeof(T));
    else std::allocator<T>{}.deallocate(p,count);
  }
  template<class U> bool operator==(const PlaneAllocator<U>&) const noexcept {return true;}
 private:
  static constexpr bool mapped([[maybe_unused]] std::size_t count) noexcept {
#if __has_feature(address_sanitizer)
    return false;
#else
    return count >= (1024*1024)/sizeof(T);
#endif
  }
};
using BytePlane = std::vector<std::uint8_t,PlaneAllocator<std::uint8_t>>;
using FloatPlane = std::vector<float,PlaneAllocator<float>>;
}  // namespace hyperdr
