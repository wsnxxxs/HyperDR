#pragma once
#include "hyperdr/container/heif_writer.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <string>

namespace writer_fixture {
using Bytes = std::vector<std::uint8_t>;
struct Sequence { Bytes vps, sps, pps; std::vector<Bytes> samples; };
inline std::filesystem::path root() { return HYPERDR_HEIF_FIXTURES; }
inline Sequence sequence(unsigned depth, std::size_t count) {
  std::ifstream input(root() / ("params" + std::to_string(depth) + ".txt"));
  if (!input) throw std::runtime_error("missing HEVC parameter fixture");
  Sequence out;
  for (auto* set : {&out.vps, &out.sps, &out.pps}) {
    std::string text; input >> text;
    if (text.empty() || text.size() % 2) throw std::runtime_error("invalid HEVC parameter fixture");
    for (std::size_t at = 0; at < text.size(); at += 2)
      set->push_back(static_cast<std::uint8_t>(std::stoul(text.substr(at, 2), nullptr, 16)));
  }
  for (std::size_t i = 0; i < count; ++i)
    out.samples.push_back({0,0,0,4,0x26,1,0x80,static_cast<std::uint8_t>(1+i%254)});
  return out;
}
inline hyperdr::GainMapMetadata metadata(bool multichannel) {
  hyperdr::GainMapMetadata out;
  out.gain_max = {3,1}; out.alternate_headroom = {3,1};
  out.base_offset = {1,100}; out.alternate_offset = {1,50};
  if (multichannel) {
    out.flags |= 0x80;
    out.channels = {{{-1,2},{3,1},{1,1},{1,100},{1,50}},
                    {{0,1},{5,2},{3,2},{2,100},{2,50}},
                    {{0,1},{2,1},{2,1},{3,100},{3,50}}};
  }
  return out;
}
inline std::vector<std::string> names() {
  return {"single8", "single10-crop", "grid10-hlg", "adaptive8-grid", "adaptive10-crop"};
}
inline Bytes file(const std::string& name, const hyperdr::HeifByteSink& sink = {}) {
  using namespace hyperdr;
  const bool adaptive = name.starts_with("adaptive");
  const bool eight = name == "single8" || name == "adaptive8-grid";
  const bool grid = name == "grid10-hlg" || name == "adaptive8-grid";
  auto base_sequence = sequence(eight ? 8 : 10, grid ? 4 : 1);
  auto gain_sequence = sequence(10, grid ? 4 : 1);
  const auto icc = read_binary_file(root() / "display-p3.icc");
  HeifEncodedImage base{base_sequence, grid ? 700U : name == "single8" ? 512U : 127U,
      grid ? 513U : name == "single8" ? 512U : 95U, {}, std::nullopt, {}};
  if (!adaptive && !eight) {
    base.color = {9, static_cast<std::uint16_t>(grid ? 18 : 16), 9, true};
    base.light = HeifContentLight{1000,400};
  }
  HeifEncodedImage gain{gain_sequence, grid ? 600U : 64U, grid ? 513U : 48U, {2,2,1,true}, std::nullopt, {}};
  HeifWriteOptions options;
  if (adaptive) {
    base.display_p3_icc = icc;
    options.gain_metadata = metadata(grid);
    PhotoMetadata capture;
    // Fixture metadata stays fixed when the product version changes.
    capture.software = "HyperDR 1.0.0";
    capture.make = "HyperDR"; capture.model = "V2 fixture"; capture.iso = 400;
    capture.exposure_seconds = 1.0/125; capture.copyright = "CC0 synthetic fixture";
    options.exif = make_minimal_exif(capture);
    options.xmp = make_xmp(capture, 3, true);
  }
  if (sink) { write_heif_to(sink, base, adaptive ? &gain : nullptr, options); return {}; }
  return write_heif(base, adaptive ? &gain : nullptr, options);
}
} // namespace writer_fixture
