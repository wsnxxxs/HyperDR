#pragma once
#include <algorithm>
#include <limits>

#include "hyperdr/container/heif_reader.hpp"
namespace hyperdr::container {
inline void require_heif(bool condition, const char* message) {
  if (!condition) throw HeifReadError(message);
}
// All cursors are bounded spans. Subtraction precedes addition, so claimed
// 64-bit sizes/offsets cannot wrap or produce an out-of-bounds subspan.
class BmffCursor {
 public:
  explicit BmffCursor(std::span<const std::uint8_t> data) : data_(data) {}
  [[nodiscard]] std::size_t remaining() const noexcept { return data_.size() - at_; }
  [[nodiscard]] std::size_t position() const noexcept { return at_; }
  std::uint64_t integer(unsigned n) {
    require_heif(n <= 8 && n <= remaining(), "truncated HEIF field");
    std::uint64_t out = 0;
    while (n--) out = (out << 8) | data_[at_++];
    return out;
  }
  std::span<const std::uint8_t> take(std::size_t n) {
    require_heif(n <= remaining(), "truncated HEIF payload");
    auto out = data_.subspan(at_, n);
    at_ += n;
    return out;
  }
  std::string text(std::size_t n) {
    auto s = take(n);
    return {reinterpret_cast<const char*>(s.data()), s.size()};
  }
  std::string cstring() {
    auto s = data_.subspan(at_);
    auto end = std::find(s.begin(), s.end(), 0);
    require_heif(end != s.end(), "unterminated HEIF string");
    return text(static_cast<std::size_t>(end - s.begin()) + 1)
        .substr(0, static_cast<std::size_t>(end - s.begin()));
  }
  void end() const { require_heif(!remaining(), "unexpected HEIF trailing bytes"); }

 private:
  std::span<const std::uint8_t> data_;
  std::size_t at_{};
};
struct BmffBox {
  std::string type;
  std::uint64_t offset{}, size{};
  unsigned header{};
  std::span<const std::uint8_t> payload;
};
inline std::vector<BmffBox> bmff_boxes(std::span<const std::uint8_t> data, std::uint64_t origin,
                                       unsigned depth, std::size_t& count) {
  require_heif(depth <= heif_limits::box_depth, "HEIF box nesting is too deep");
  BmffCursor c(data);
  std::vector<BmffBox> out;
  while (c.remaining()) {
    require_heif(count < heif_limits::boxes, "HEIF contains too many boxes");
    ++count;
    const auto start = c.position();
    auto size = c.integer(4);
    auto type = c.text(4);
    unsigned header = 8;
    if (size == 1) {
      size = c.integer(8);
      header = 16;
    } else if (!size) {
      require_heif(depth == 0, "HEIF size-zero box is not top-level");
      size = data.size() - start;
    }
    require_heif(size >= header && size - header <= c.remaining(), "invalid HEIF box size");
    auto payload = c.take(static_cast<std::size_t>(size - header));
    out.push_back({std::move(type), origin + start, size, header, payload});
  }
  return out;
}
inline std::pair<unsigned, unsigned> bmff_fullbox(BmffCursor& c, unsigned maximum = 0) {
  auto version = static_cast<unsigned>(c.integer(1));
  auto flags = static_cast<unsigned>(c.integer(3));
  require_heif(version <= maximum, "unsupported HEIF box version");
  return {version, flags};
}
inline std::uint64_t checked_grid_tile_count(std::uint32_t rows, std::uint32_t columns) {
  require_heif(rows && columns && rows <= 256 && columns <= 256 &&
                   std::uint64_t(rows) * columns <= heif_limits::grid_tiles,
               "HEIF grid tile count exceeds limit");
  return std::uint64_t(rows) * columns;
}
inline std::uint64_t heif_add(std::uint64_t a, std::uint64_t b) {
  require_heif(b <= std::numeric_limits<std::uint64_t>::max() - a, "HEIF offset overflow");
  return a + b;
}
}  // namespace hyperdr::container
