#include "hyperdr/container/heif_writer.hpp"
#include "internal/boxes.hpp"
#include "internal/hevc_bits.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include <limits>

namespace hyperdr {
namespace {
using container::Bytes;
constexpr auto limit = std::numeric_limits<std::uint32_t>::max() - 8U;
void add(Bytes& out, std::span<const std::uint8_t> nal, bool annexb) {
  (void)container::nal_type(nal);
  if (nal.size() > limit - 4 || out.size() > limit - 4 - nal.size())
    throw std::invalid_argument("HEVC sample is too large");
  container::put32(out, annexb ? 1 : static_cast<std::uint32_t>(nal.size()));
  out.insert(out.end(), nal.begin(), nal.end());
}
std::size_t start_code(std::span<const std::uint8_t> bytes, std::size_t offset) {
  if (bytes.size() - offset >= 4 && bytes[offset] == 0 && bytes[offset+1] == 0 &&
      bytes[offset+2] == 0 && bytes[offset+3] == 1) return 4;
  if (bytes.size() - offset >= 3 && bytes[offset] == 0 && bytes[offset+1] == 0 && bytes[offset+2] == 1) return 3;
  return 0;
}
}
std::vector<std::uint8_t> hevc_annexb_to_sample(std::span<const std::uint8_t> input) {
  if (input.empty() || input.size() > limit) throw std::invalid_argument("invalid Annex-B size");
  std::size_t at = 0;
  while (at < input.size() && !start_code(input, at)) {
    if ((at & 65535U) == 0) check_cancelled();
    if (input[at++] != 0) throw std::invalid_argument("missing Annex-B start code");
  }
  if (at == input.size()) throw std::invalid_argument("missing Annex-B NAL units");
  Bytes out;
  while (at < input.size()) {
    check_cancelled();
    const auto begin = at + start_code(input, at);
    auto end = begin;
    while (end < input.size() && !start_code(input, end)) {
      if ((end & 65535U) == 0) check_cancelled();
      ++end;
    }
    at = end;
    while (end > begin && input[end-1] == 0) --end; // trailing_zero_8bits
    add(out, input.subspan(begin, end - begin), false);
  }
  return out;
}
std::vector<std::uint8_t> hevc_sample_to_annexb(std::span<const std::uint8_t> input) {
  if (input.empty() || input.size() > limit) throw std::invalid_argument("invalid HEVC sample size");
  Bytes out;
  for (std::size_t at = 0; at < input.size();) {
    check_cancelled();
    if (input.size() - at < 4) throw std::invalid_argument("truncated HEVC NAL length");
    const auto size = container::be32(input, at); at += 4;
    if (size > input.size() - at) throw std::invalid_argument("HEVC NAL length exceeds sample");
    add(out, input.subspan(at, size), true);
    at += size;
  }
  return out;
}
} // namespace hyperdr
