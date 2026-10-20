#pragma once

// Write-only HEIF packaging of one VT EncodedSequence per logical image.
// No encoder, decoder or filesystem operations are part of this interface.
#include "hyperdr/container/iso_gain_map.hpp"
#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <vector>

namespace hyperdr {

// Borrow EncodedSequence's four byte arrays without depending upward on codec.
// Lvalues only: the sequence must outlive the call and remain unchanged during it.
struct HeifSequenceView {
  std::span<const std::uint8_t> vps, sps, pps;
  std::span<const std::vector<std::uint8_t>> samples;
  template<class Sequence> requires (!std::is_same_v<std::remove_cvref_t<Sequence>, HeifSequenceView>)
  HeifSequenceView(Sequence& sequence)
      : vps(sequence.vps), sps(sequence.sps), pps(sequence.pps), samples(sequence.samples) {}
  // File-backed samples: only their lengths remain resident. The reader must
  // return exactly one sample and may throw; it is never called concurrently.
  std::span<const std::size_t> stored_sizes;
  std::function<std::vector<std::uint8_t>(std::size_t)> read_stored;
  template<class Sequence> HeifSequenceView(Sequence& sequence,
      std::span<const std::size_t> sizes,
      std::function<std::vector<std::uint8_t>(std::size_t)> read)
      : vps(sequence.vps), sps(sequence.sps), pps(sequence.pps),
        stored_sizes(sizes), read_stored(std::move(read)) {}
  std::size_t count() const { return read_stored ? stored_sizes.size() : samples.size(); }
  std::size_t size(std::size_t index) const {
    return read_stored ? stored_sizes[index] : samples[index].size();
  }
  void visit(std::size_t index, const std::function<void(std::span<const std::uint8_t>)>& use) const {
    if (!read_stored) { use(samples[index]); return; }
    const auto bytes = read_stored(index);
    if (bytes.size() != stored_sizes[index]) throw std::runtime_error("HEIF stored sample length changed");
    use(bytes);
  }
};

struct HevcConfiguration {
  std::vector<std::uint8_t> record; // hvcC payload, without a box header
  std::uint32_t width{}, height{}; // SPS display dimensions
  unsigned bit_depth{}, chroma_format{};
};
// Parses each single-layer Main/Main10 parameter set through its rbsp
// trailing bits; truncated sets and any extension syntax throw invalid_argument.
[[nodiscard]] HevcConfiguration make_hevc_configuration(
    std::span<const std::uint8_t> vps, std::span<const std::uint8_t> sps,
    std::span<const std::uint8_t> pps);

// Byte framing only: validate NAL boundaries/headers; do not decode slices.
[[nodiscard]] std::vector<std::uint8_t> hevc_annexb_to_sample(std::span<const std::uint8_t> annexb);
[[nodiscard]] std::vector<std::uint8_t> hevc_sample_to_annexb(std::span<const std::uint8_t> sample);

struct HeifNclx {
  std::uint16_t primaries{12}, transfer{13}, matrix{1};
  bool full_range{true};
};
struct HeifContentLight {
  std::uint16_t maximum{}, average{};
};
struct HeifEncodedImage {
  HeifSequenceView sequence;
  std::uint32_t width{}, height{}; // oriented output size; row-major 512 tiles
  HeifNclx color{};                // authoritative; never inferred from ICC
  std::optional<HeifContentLight> light;
  // Only the Adaptive base carries this matching Display P3 ICC profile.
  std::span<const std::uint8_t> display_p3_icc;
};
struct HeifWriteOptions {
  // An optional second image is the ISO gain map; base is always primary.
  std::optional<GainMapMetadata> gain_metadata;
  std::vector<std::uint8_t> exif; // TIFF bytes, without HEIF's four-byte offset
  std::string xmp;
};

// Bounded to 4096 tiles across base and gain map, 256 per axis, and a <4 GiB
// 32-bit iloc file; tmap extraction and inspect_heif read every such file.
// Adaptive mode requires gain + gain_metadata + a matching base P3 ICC.
// Only an exact 512x512 image is a bare hvc1; all cropping uses grid output
// dimensions, including a 1x1 grid. No clean-aperture property is written.
// nclx is essential, ICC is descriptive. No post-write metadata surgery.
[[nodiscard]] std::vector<std::uint8_t> write_heif(
    const HeifEncodedImage& base, const HeifEncodedImage* gain = nullptr,
    const HeifWriteOptions& options = {});

// Synchronous append-only sink. Each borrowed span is valid only during the
// callback; write it completely or throw. Exceptions/cancellation propagate.
// Metadata offsets are calculated before the first byte; no seek is needed.
using HeifByteSink = std::function<void(std::span<const std::uint8_t>)>;
void write_heif_to(const HeifByteSink& sink, const HeifEncodedImage& base,
    const HeifEncodedImage* gain = nullptr, const HeifWriteOptions& options = {});

} // namespace hyperdr
