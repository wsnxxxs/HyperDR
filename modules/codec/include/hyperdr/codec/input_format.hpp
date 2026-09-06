#pragma once

// What kind of image a file actually is, decided by its leading bytes.
//
// Every layer of this project used to answer that question for itself, and each
// one answered it from the file name: the CLI's discovery filter, the panel's
// upload guard, the browser's `accept` attribute, the native file dialog, and
// the decoder dispatch. Five copies of one list, and a name is not evidence --
// a phone gallery exports HEIC under a `.jpg` suffix routinely, and the plain
// JPEG decoder simply rejected those.
//
// This header is the single source. `HyperDR schema` emits the two tables below
// so the panel derives its own copy instead of mirroring one by hand, exactly
// as it already does for the settings vocabulary.
//
// Nothing here reads a file. The tables describe a prefix, and
// `kSignaturePrefixBytes` is how much of one is enough: answering "is this an
// AVIF" by reading a 50 MB image would double the cost of decoding it.

#include "hyperdr/codec/image_source.hpp"

#include <array>
#include <cstdint>
#include <span>
#include <string_view>

namespace hyperdr {

// Filename filters for discovery and the panel's file dialog. The decoders
// remain the authority on contents: accepting an extension here does not make a
// malformed file decode, and rejecting one does not mean the bytes are bad.
//
// Grouped by family rather than listed flat, because the panel needs to know
// which family a name claims -- that is how it decides whether a `.jpg` holding
// HEIC should be stored under the name it arrived with or the one its bytes
// deserve. The flat list every other caller wants is built from these below, so
// the two cannot disagree.
inline constexpr std::array<std::string_view, 2> kJpegExtensions{".jpg", ".jpeg"};
inline constexpr std::array<std::string_view, 1> kPngExtensions{".png"};
inline constexpr std::array<std::string_view, 3> kIsobmffExtensions{
    ".heic", ".heif", ".avif"};

[[nodiscard]] consteval auto join_raster_extensions() {
  std::array<std::string_view, kJpegExtensions.size() + kPngExtensions.size() +
                                   kIsobmffExtensions.size()>
      all{};
  std::size_t next = 0;
  for (const auto extension : kJpegExtensions) all[next++] = extension;
  for (const auto extension : kPngExtensions) all[next++] = extension;
  for (const auto extension : kIsobmffExtensions) all[next++] = extension;
  return all;
}

inline constexpr auto kRasterInputExtensions = join_raster_extensions();

// The raster families the dispatcher can tell apart from bytes alone.
//
// `Isobmff` deliberately stops at the container. HEIF and AVIF are the same box
// structure and differ only in the codec inside, which libheif and libavif
// answer far better than a brand-string table would; `decode_image` asks
// `is_avif_bytes` once it has the file. RAW is absent for the opposite reason:
// most RAW formats *are* TIFF, so a signature cannot separate a `.dng` from an
// unrelated TIFF or distinguish one camera format from another. The extension
// routes it to LibRaw, and LibRaw is the content authority.
enum class InputFormat : std::uint8_t {
  Unknown,
  Jpeg,
  Png,
  Isobmff,
};

[[nodiscard]] constexpr std::string_view input_format_name(InputFormat format) {
  switch (format) {
    case InputFormat::Jpeg: return "jpeg";
    case InputFormat::Png: return "png";
    case InputFormat::Isobmff: return "isobmff";
    case InputFormat::Unknown: break;
  }
  return "unknown";
}

// The extension this project writes a file of `format` under. An ISO base media
// file is named `.heic` whatever codec it carries, because that is the name the
// HEIF branch of `decode_image` routes through -- and that branch already sends
// an AV1 payload to the AVIF decoder.
[[nodiscard]] constexpr std::string_view canonical_extension(InputFormat format) {
  switch (format) {
    case InputFormat::Jpeg: return ".jpg";
    case InputFormat::Png: return ".png";
    case InputFormat::Isobmff: return ".heic";
    case InputFormat::Unknown: break;
  }
  return {};
}

// Which family a filename claims. Unknown for a RAW or unrecognised extension.
//
// Exercised by discovery_test rather than by the pipeline, which decides from
// bytes: this is the other half of that comparison, and the test's point is
// that a name and its contents can disagree.
[[nodiscard]] constexpr InputFormat extension_format(std::string_view extension) {
  for (const auto candidate : kJpegExtensions) {
    if (candidate == extension) return InputFormat::Jpeg;
  }
  for (const auto candidate : kPngExtensions) {
    if (candidate == extension) return InputFormat::Png;
  }
  for (const auto candidate : kIsobmffExtensions) {
    if (candidate == extension) return InputFormat::Isobmff;
  }
  return InputFormat::Unknown;
}

struct InputSignature {
  std::uint32_t offset;
  std::string_view magic;
};

// `sizeof(literal) - 1` rather than strlen, so a magic containing NUL -- which
// half the TIFF variants below do -- keeps its real length.
template <std::size_t N>
[[nodiscard]] consteval std::string_view magic_literal(const char (&text)[N]) {
  return std::string_view(text, N - 1);
}

inline constexpr std::array<InputSignature, 1> kJpegSignatures{{
    {0, magic_literal("\xff\xd8\xff")},
}};

inline constexpr std::array<InputSignature, 1> kPngSignatures{{
    {0, magic_literal("\x89\x50\x4e\x47\x0d\x0a\x1a\x0a")},
}};

inline constexpr std::array<InputSignature, 1> kIsobmffSignatures{{
    {4, magic_literal("ftyp")},
}};

// Enough for JPEG, PNG, and ISO-BMFF. RAW does not participate in signature
// probing; reading more bytes cannot make its generic container headers
// authoritative.
inline constexpr std::size_t kSignaturePrefixBytes = 16;

[[nodiscard]] inline bool matches_signature(std::span<const std::uint8_t> head,
                                            const InputSignature& signature) {
  const std::size_t end = signature.offset + signature.magic.size();
  if (head.size() < end) return false;
  return std::string_view(reinterpret_cast<const char*>(head.data()) + signature.offset,
                          signature.magic.size()) == signature.magic;
}

template <std::size_t N>
[[nodiscard]] inline bool matches_any(std::span<const std::uint8_t> head,
                                      const std::array<InputSignature, N>& table) {
  for (const auto& signature : table) {
    if (matches_signature(head, signature)) return true;
  }
  return false;
}

// Which raster family these leading bytes are, or Unknown.
[[nodiscard]] inline InputFormat probe_input_signature(std::span<const std::uint8_t> head) {
  if (matches_any(head, kJpegSignatures)) return InputFormat::Jpeg;
  if (matches_any(head, kPngSignatures)) return InputFormat::Png;
  if (matches_any(head, kIsobmffSignatures)) return InputFormat::Isobmff;
  return InputFormat::Unknown;
}

}  // namespace hyperdr
