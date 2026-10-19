#pragma once

// HEVC through VideoToolbox, the only HEVC encoder the engine has.
//
// There is one backend, so there is no backend interface: when a second one
// exists it can be abstracted then. The surface is what a HEIF writer needs --
// a picture is a row-major run of 512x512 tiles, each encoded as one keyframe of
// a single VTCompressionSession, so every tile of a logical image (base, gain
// map, PQ or HLG primary) shares one VPS / SPS / PPS and therefore one hvcC.
//
// Everything here is plain C++ over the VideoToolbox, CoreMedia and CoreVideo
// C APIs; no Objective-C.

#include <cstdint>
#include <filesystem>
#include <functional>
#include <span>
#include <string>
#include <vector>

namespace hyperdr::codec::hevc {

// Reason codes, shared with the engine's capabilities report.
inline constexpr const char* kReasonUnavailable = "hevc_unavailable";
inline constexpr const char* kReasonMain10Unavailable = "hevc_main10_unavailable";
inline constexpr const char* kReasonProbeFailed = "hevc_probe_failed";

struct EncoderCaps {
  bool main8{false}, main10{false};
  // Empty when both profiles work. Otherwise one of the reasons above:
  // `hevc_unavailable` when 8-bit encoding is impossible (no encoder),
  // `hevc_probe_failed` when it was possible to start but the round trip did
  // not verify, `hevc_main10_unavailable` when only Main10 is missing.
  std::string reason_code;
  // Human-readable diagnostics for logs and tests; never shown to users.
  std::string detail;
};

// Probes on first use and caches the answer for the process. With a cache
// directory, a fully successful probe is also remembered there per macOS build,
// so later processes skip the encode. A failed probe is never written to disk:
// it costs a few hundred milliseconds to repeat, and remembering a transient
// failure would hide the format until the next OS update.
[[nodiscard]] EncoderCaps encoder_caps(const std::filesystem::path& cache_directory = {});

// Forgets the process answer and disk caches in every directory used by this
// process. `encode` calls it when
// VideoToolbox fails, so the next capabilities query probes again.
void invalidate_encoder_caps();

inline constexpr std::uint32_t kTileSize = 512;

// One 512x512 picture in VideoToolbox's full-range bi-planar 4:2:0 layout:
// NV12 (one byte per sample) at 8 bits, P010 (little-endian 16-bit words with
// the 10-bit code in the high bits) at 10.
struct YuvTile {
  int bit_depth{8};
  std::vector<std::uint8_t> luma;    // kTileSize rows of kTileSize samples
  std::vector<std::uint8_t> chroma;  // kTileSize / 2 rows of kTileSize / 2 CbCr pairs

  [[nodiscard]] std::size_t sample_bytes() const noexcept { return bit_depth > 8 ? 2 : 1; }
  [[nodiscard]] std::size_t luma_row_bytes() const noexcept { return kTileSize * sample_bytes(); }
  [[nodiscard]] std::size_t chroma_row_bytes() const noexcept { return kTileSize * sample_bytes(); }
  // Code values, without the P010 shift.
  [[nodiscard]] unsigned luma_at(std::uint32_t x, std::uint32_t y) const noexcept;
  [[nodiscard]] unsigned cb_at(std::uint32_t x, std::uint32_t y) const noexcept;  // chroma coordinates
  [[nodiscard]] unsigned cr_at(std::uint32_t x, std::uint32_t y) const noexcept;
};

[[nodiscard]] YuvTile make_tile(int bit_depth);

// ITU-T H.273 code points describing the samples, written into the bitstream's
// VUI so it agrees with the container's `colr nclx`. 2 means unspecified, and
// leaves the corresponding VUI field unset. Samples are always full range.
struct ColorDescription {
  int primaries{2}, transfer{2}, matrix{2};
};

struct EncodeParams {
  int quality{90};          // 0-100, mapped by `vt_quality`
  bool main10{false};       // tiles must then be 10-bit
  bool prefer_speed{false}; // `hevc_preset = medium`
  ColorDescription color{};
};

struct EncodedSequence {
  std::vector<std::uint8_t> vps, sps, pps;            // NAL units without length or start code, for hvcC
  std::vector<std::vector<std::uint8_t>> samples;     // one IDR picture per tile, 4-byte length-prefixed NAL units
};

// Fills `tile` (already sized by `make_tile`) with picture `index`. Called on
// the encoding thread, in order, one tile at a time.
using TileProducer = std::function<void(std::size_t index, YuvTile& tile)>;

// Encodes `count` tiles, in order, as one sequence. Tiles are produced one at a
// time and at most a few are in flight inside VideoToolbox, so a large picture
// never exists as a whole in YUV. Checks for cancellation between tiles
// (throws `Cancelled`); throws std::invalid_argument for bad parameters and
// std::runtime_error when VideoToolbox fails, and only the latter invalidates
// the cached capabilities.
[[nodiscard]] EncodedSequence encode(std::size_t count, const TileProducer& produce,
                                     const EncodeParams& params);
[[nodiscard]] EncodedSequence encode(std::span<const YuvTile> tiles, const EncodeParams& params);

// Decodes a sequence produced by `encode` back into tiles of the given depth.
// Thin convenience over decode_item, used by the probe and encoder tests.
[[nodiscard]] std::vector<YuvTile> decode(const EncodedSequence& sequence, int bit_depth);

// The colour description and range CoreMedia reads from the SPS VUI, mapped back
// to H.273 code points (2 where the VUI is silent), so tests can check that the
// bitstream agrees with the container's nclx.
struct BitstreamColor {
  ColorDescription color;
  bool full_range{false};
};
[[nodiscard]] BitstreamColor bitstream_color(const EncodedSequence& sequence);

// `quality` (0-100) to kVTCompressionPropertyKey_Quality (0-1). Monotonic and
// provisional: P3a-2 calibrates it against the sample set.
[[nodiscard]] float vt_quality(int quality);

// --- Tiling and colour conversion ------------------------------------------

struct TileGrid {
  std::uint32_t width{}, height{}, columns{}, rows{};
  [[nodiscard]] std::size_t count() const noexcept {
    return static_cast<std::size_t>(columns) * rows;
  }
};
[[nodiscard]] TileGrid tile_grid(std::uint32_t width, std::uint32_t height);

// Fills `rgb` with `count` interleaved R'G'B' triples of row `y`, starting at
// column `x0`: transfer-encoded values in [0, 1] (they are clamped). Called
// concurrently for different rows, so it must not mutate shared state.
using RgbRowReader =
    std::function<void(std::uint32_t y, std::uint32_t x0, std::uint32_t count, float* rgb)>;
// The same for a single channel (a gain map), `count` values.
using LumaRowReader =
    std::function<void(std::uint32_t y, std::uint32_t x0, std::uint32_t count, float* value)>;

// Converts tile `index` (row-major in `grid`) of an image to full-range 4:2:0
// with the given H.273 matrix (1 = BT.709, 9 = BT.2020 non-constant
// luminance). Chroma is the mean of each 2x2 block. Past the right and bottom
// edges the last column and row repeat; the HEIF grid crops them. NaN reads as
// 0. With `dither`, every code is quantised with the deterministic TPDF dither
// the RGB paths use, keyed on picture coordinates, so a tile does not depend on
// which tiles were converted before it or on the number of workers.
void rgb_tile(const TileGrid& grid, std::size_t index, const RgbRowReader& read, int matrix,
              bool dither, YuvTile& tile);

// A single channel as luma with neutral chroma, rounded without dither (the
// gain-map encoding).
void luma_tile(const TileGrid& grid, std::size_t index, const LumaRowReader& read,
               YuvTile& tile);

// Whole-image conveniences over the two above, for tests and small pictures.
[[nodiscard]] std::vector<YuvTile> tiles_from_rgb(
    std::uint32_t width, std::uint32_t height, const RgbRowReader& read, int matrix,
    int bit_depth, bool dither);
[[nodiscard]] std::vector<YuvTile> tiles_from_luma(
    std::uint32_t width, std::uint32_t height, const LumaRowReader& read, int bit_depth);

}  // namespace hyperdr::codec::hevc

namespace hyperdr {
struct HvcConfig;
struct HeifNclx;
class CancelToken;
} // namespace hyperdr
namespace hyperdr::codec::hevc {
// Native YUV codes copied out of one VT image buffer. Rows are tightly packed;
// 10-bit values occupy the high bits of little-endian 16-bit words (P010/etc).
// Chroma is interleaved CbCr, empty for monochrome. No RGB conversion occurs in
// VT.
struct DecodedPicture {
  std::uint32_t width{}, height{};
  unsigned bit_depth{}, chroma_format{};
  std::vector<std::uint8_t> luma, chroma;
  [[nodiscard]] unsigned sample_bytes() const noexcept {
    return bit_depth > 8 ? 2 : 1;
  }
  [[nodiscard]] unsigned chroma_width() const noexcept;
  [[nodiscard]] unsigned chroma_height() const noexcept;
  [[nodiscard]] std::size_t luma_row_bytes() const noexcept {
    return std::size_t(width) * sample_bytes();
  }
  [[nodiscard]] std::size_t chroma_row_bytes() const noexcept {
    return std::size_t(chroma_width()) * 2 * sample_bytes();
  }
  [[nodiscard]] unsigned luma_at(unsigned x, unsigned y) const noexcept;
  [[nodiscard]] unsigned cb_at(unsigned x, unsigned y) const noexcept;
  [[nodiscard]] unsigned cr_at(unsigned x, unsigned y) const noexcept;
};
// Reader spans must remain valid until the next reader call. VT receives its
// own CMBlockBuffer copy, so a reader can reuse storage for joined extents.
using EncodedTileReader =
    std::function<std::span<const std::uint8_t>(std::size_t)>;
using DecodedTileSink = std::function<void(std::size_t, DecodedPicture &&)>;
struct DecodeParams {
  const CancelToken *cancel{}; // null inherits the operation's current token
  std::function<void(std::size_t completed, std::size_t total)> progress;
  unsigned max_in_flight{}; // 0: up to four, reduced for large tiles
};
// One item / hvcC / VT session. Output sinks run on the caller, in tile order;
// VT may decode subsequent tiles while a sink converts the preceding one.
void decode_item(const HvcConfig &, std::size_t count,
                 const EncodedTileReader &, const DecodedTileSink &,
                 const DecodeParams & = {});
struct YuvRgbParams {
  int matrix{6}; // unspecified (2) follows libheif 1.23's BT.601 default
  bool full_range{false};
  unsigned chroma_location{
      1}; // absent VUI: centered; explicit H.265 types 0..5
  bool parallel_rows{true};
  const CancelToken *cancel{};
};
[[nodiscard]] YuvRgbParams conversion_params(const HvcConfig &,
                                             const HeifNclx *nclx = nullptr);
// Normalized encoded R'G'B', before transfer decoding. Preserve excursions
// below zero and above one: these are gamut information, not invalid samples.
// Rows may run concurrently; each span is valid only during the callback.
// Monochrome gain maps consume luma_at directly, without this conversion.
using RgbFloatRowSink = std::function<void(unsigned row, std::span<const float>)>;
void yuv_to_rgb(const DecodedPicture &, const YuvRgbParams &, const RgbFloatRowSink &);
}  // namespace hyperdr::codec::hevc
