#pragma once

// Write-only HEIF packaging of one VT EncodedSequence per logical image.
// No encoder, decoder or filesystem operations are part of this interface.
#include "hyperdr/container/iso_gain_map.hpp"
#include <cstdint>
#include <functional>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace hyperdr {

// Borrow EncodedSequence's four byte arrays without depending upward on codec.
// Lvalues only: the sequence must outlive the call and remain unchanged during it.
struct HeifSequenceView {
  std::span<const std::uint8_t> vps, sps, pps;
  std::span<const std::vector<std::uint8_t>> samples;
  template<class Sequence> HeifSequenceView(Sequence& sequence)
      : vps(sequence.vps), sps(sequence.sps), pps(sequence.pps), samples(sequence.samples) {}
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
