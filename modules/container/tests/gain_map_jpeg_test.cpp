#include "hyperdr/container/gain_map_jpeg.hpp"
#include "hyperdr/foundation/cancel.hpp"
#include <algorithm>
#include <iostream>
#include <fstream>
#include <iterator>
#include <filesystem>
#include <stdexcept>
#include <vector>

namespace {
using Bytes = std::vector<std::uint8_t>;
void require(bool v, const char* message) { if (!v) throw std::runtime_error(message); }
template<class F> void rejects(F f) {
  try { f(); } catch (const std::invalid_argument&) { return; }
  throw std::runtime_error("malformed JPEG accepted");
}
// Minimal marker stream with an APP0, a scan, stuffed FF and a restart.
const Bytes primary{255,216,255,224,0,4,1,2,
  255,192,0,11,8,0,1,0,1,1,1,17,0,
  255,218,0,8,1,1,0,0,63,0,1,255,0,2,255,208,3,255,217};
const Bytes gain{255,216,255,192,0,11,8,0,1,0,1,1,1,17,0,
  255,218,0,8,1,1,0,0,63,0,1,255,0,2,255,217};
Bytes fixture(const char* name) {
  const auto path = std::filesystem::path(HYPERDR_JPEG_FIXTURES) / name;
  std::ifstream input(path, std::ios::binary);
  if (!input) throw std::runtime_error("missing JPEG golden fixture");
  return Bytes(std::istreambuf_iterator<char>(input), {});
}
void golden() {
  for (bool rgb : {false,true}) {
    hyperdr::GainMapMetadata m;
    m.base_offset = m.alternate_offset = {1,64};
    if (rgb) {
      m.flags |= 0x80;
      m.channels = {{{-1,1},{1,1},{1,1},{1,64},{2,64}},
                    {{-2,1},{2,1},{2,1},{3,64},{4,64}},
                    {{-3,1},{3,1},{3,1},{5,64},{6,64}}};
    }
    const auto bytes = hyperdr::assemble_gain_map_jpeg(fixture("primary.jpg"),
        fixture(rgb?"rgb-gain.jpg":"mono-gain.jpg"), m);
    require(bytes == fixture(rgb?"rgb.jpg":"mono.jpg"), "gain-map JPEG golden changed");
    (void)hyperdr::parse_gain_map_jpeg(bytes);
  }
}
void round_trip(bool rgb, bool common) {
  hyperdr::GainMapMetadata m;
  m.gain_min = {-2,1}; m.gain_max = {4,1}; m.base_offset = {1,64}; m.alternate_offset = {1,64};
  if (rgb) {
    m.flags |= 0x80;
    m.channels = {{{-1,1},{2,1},{1,1},{1,64},{2,64}},
                  {{-2,1},{3,1},{2,1},{3,64},{4,64}},
                  {{-3,1},{4,1},{3,1},{5,64},{6,64}}};
  }
  if (common) {
    m.common_denominator = true;
    m.base_headroom = {0,64}; m.alternate_headroom = {256,64};
    if (rgb) for (auto& c : m.channels) {
      c.gain_min = {-64,64}; c.gain_max = {256,64}; c.gamma = {64,64};
    } else {
      m.gain_min = {-64,64}; m.gain_max = {256,64}; m.gamma = {64,64};
    }
  }
  const auto bytes = hyperdr::assemble_gain_map_jpeg(primary, gain, m);
  require(bytes == hyperdr::assemble_gain_map_jpeg(primary, gain, m), "writer is not deterministic");
  const auto parsed = hyperdr::parse_gain_map_jpeg(bytes);
  require(parsed.mpf_count == 1 && parsed.primary_iso_count == 1 && parsed.gain_iso_count == 1,
      "wrong APP segment counts");
  require(!parsed.has_hdrgm && !parsed.has_container_directory, "legacy metadata emitted");
  require(hyperdr::serialize_tmap_payload(parsed.metadata) == hyperdr::serialize_tmap_payload(m),
      "metadata changed");
  require(parsed.app_segments[0][0].offset == 2 && parsed.app_segments[0][0].payload == Bytes({1,2}),
      "primary APP marker changed");
  require(bytes[parsed.gain_offset] == 255 && bytes[parsed.gain_offset+1] == 216, "MPF misses gain SOI");
  // Every truncation is rejected, including offsets into entropy data.
  for (std::size_t n = 0; n < bytes.size(); ++n)
    rejects([&] { (void)hyperdr::parse_gain_map_jpeg(Bytes(bytes.begin(), bytes.begin()+n)); });
  for (const auto& app : parsed.app_segments[0]) if (app.payload.size() > 4 && app.payload[0] == 'M') {
    auto bad = bytes; bad[app.offset + 4 + 4 + 50 + 16 + 8] ^= 1;
    rejects([&] { (void)hyperdr::parse_gain_map_jpeg(bad); });
    bad = bytes; bad[app.offset + 2] = 255; bad[app.offset + 3] = 255;
    rejects([&] { (void)hyperdr::parse_gain_map_jpeg(bad); });
  }
  auto padded = primary; padded.insert(padded.begin() + 2, 255);
  const auto with_fill = hyperdr::parse_gain_map_jpeg(hyperdr::assemble_gain_map_jpeg(padded, gain, m));
  require(with_fill.app_segments[0][0].offset == 3, "JPEG marker fill shifted MPF origin");
  auto extra = bytes; extra.push_back(0);
  rejects([&] { (void)hyperdr::parse_gain_map_jpeg(extra); });
  rejects([&] { (void)hyperdr::assemble_gain_map_jpeg(bytes, gain, m); });
  rejects([&] { (void)hyperdr::assemble_gain_map_jpeg(primary, primary, m); });
}
}  // namespace
int main() {
  try {
    golden();
    for (bool rgb : {false,true}) for (bool common : {false,true}) round_trip(rgb,common);
    hyperdr::CancelToken token; token.request(); hyperdr::CancelScope scope(&token);
    try { (void)hyperdr::assemble_gain_map_jpeg(primary,gain,{}); }
    catch (const hyperdr::Cancelled&) { std::cout << "gain-map JPEG tests passed\n"; return 0; }
    throw std::runtime_error("writer ignored cancellation");
  } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
