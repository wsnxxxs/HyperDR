#pragma once

// Writing a rendered image out, and reading it back to prove it decodes.
//
// Every conversion verifies its own output by default. An encoder that produces
// a structurally valid file no decoder will open is the failure mode this
// project most needs to catch before the user does, and the only reliable check
// is to decode what was just written.

#include "hyperdr/codec/avif_grid.hpp"
#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/image/color.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace hyperdr {
class ExportDimensionLimit : public std::runtime_error {
 public:
  ExportDimensionLimit(std::uint32_t width, std::uint32_t height)
      : std::runtime_error("JPEG " + std::to_string(width) + "x" + std::to_string(height) +
                           " exceeds per-side limit 65500") {}
  // The canvas is more than libavif decodes: written, it could not be opened (or
  // verified), so the export is refused before any pixel is encoded.
  [[nodiscard]] static ExportDimensionLimit avif(std::uint32_t width, std::uint32_t height) {
    return ExportDimensionLimit("AVIF " + std::to_string(width) + "x" + std::to_string(height) +
                                " exceeds the decodable limit of " + std::to_string(kAvifDecodeMaxPixels) +
                                " pixels (16384x16384) and " + std::to_string(kAvifDecodeMaxSide) +
                                " per side");
  }

 private:
  explicit ExportDimensionLimit(const std::string& message) : std::runtime_error(message) {}
};


// Display P3 SDR base plus an ISO 21496-1 gain map, related by a `tmap` derived
// item. `depth` selects the base image's bit depth; the gain map is always 8-bit.
[[nodiscard]] std::vector<std::uint8_t> encode_adaptive_heic(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    int depth, HevcPreset preset = HevcPreset::Slow);

// SDR Display P3 primary plus an ISO 21496-1 gain map. No XMP metadata.
[[nodiscard]] std::vector<std::uint8_t> encode_gain_map_jpeg(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality);
// Owned export path releases float gain codes before allocating JPEG working planes.
[[nodiscard]] std::vector<std::uint8_t> encode_gain_map_jpeg(
    GainMapResult&& images, const PhotoMetadata& metadata, int quality);

[[nodiscard]] std::vector<std::uint8_t> encode_sdr_jpeg(
    const FloatImage& image, const PhotoMetadata& metadata, int quality,
    ColorGamut gamut = ColorGamut::kSrgb);
void verify_sdr_jpeg(std::span<const std::uint8_t> bytes);
[[nodiscard]] std::vector<std::uint8_t> encode_sdr_tiff(
    const FloatImage& image, const PhotoMetadata& metadata,
    ColorGamut gamut = ColorGamut::kDisplayP3);
void verify_sdr_tiff(std::span<const std::uint8_t> bytes);
[[nodiscard]] std::vector<std::uint8_t> encode_hdr_heic(
    const PhotoRenditions& images, const PhotoMetadata& metadata, int quality, HdrEncoding encoding,
    HevcPreset preset = HevcPreset::Slow);
// Canvases libaom cannot hold as one frame are written as a grid of cells (see
// avif_grid.hpp); `layout` overrides that choice, for tests.
[[nodiscard]] std::vector<std::uint8_t> encode_avif(
    const PhotoRenditions& images, const PhotoMetadata& metadata, int quality, HdrEncoding encoding,
    const AvifGridLayout* layout = nullptr);

// Decode-verification. Each throws with a specific reason on failure.
//
// `verify_encoded_output` is the one dispatch from an encoding to the check
// that proves the file it wrote opens; the converter and the packaging entry
// point both use it so neither can publish an unverified file.
void verify_encoded_output(std::span<const std::uint8_t> bytes, HdrEncoding encoding);
void verify_heic_decodable(std::span<const std::uint8_t> bytes);
void verify_heic_decodable(std::span<const std::uint8_t> bytes,
                           HdrEncoding encoding);
void verify_heic_decodable(const std::filesystem::path& input);
void verify_gain_map_jpeg(std::span<const std::uint8_t> bytes);
void verify_gain_map_jpeg(const std::filesystem::path& input);
void verify_avif_decodable(std::span<const std::uint8_t> bytes);

// Native-pixel file verification. Compressed files are borrowed through a
// read-only mapping; JPEG/TIFF rows and HEIC tiles never form a whole raster.
// AVIF currently retains its complete decoded YUV image (boundedMemory=false).
struct VerificationFrame {
  std::uint32_t width{},height{},x{},y{},photoWidth{},photoHeight{};
};
struct VerificationResult {
  std::uint32_t width{},height{};
  std::uint64_t pixels{};
  float gainMinimum=std::numeric_limits<float>::infinity();
  float gainMaximum=-std::numeric_limits<float>::infinity();
  bool boundedMemory=true;
};
[[nodiscard]] VerificationResult verify_encoded_file(const std::filesystem::path&,HdrEncoding,
                                                     std::optional<VerificationFrame> = {});

// Reconstructs a gain-map HEIC into a 16-bit linear TIFF, so the HDR rendition
// a display would show can be examined outside this tool.
void reconstruct_heic_to_tiff(const std::filesystem::path& input,
                              const std::filesystem::path& output);

struct DisplayCurvePoint {
  float headroom_stops{};
  double mae_linear_p3{};
  double mse_linear_p3{};
  double max_abs_error_linear_p3{};
  std::uint64_t total_values{};
  std::uint64_t reference_clamp_values{};
  std::uint64_t candidate_clamp_values{};
  std::uint64_t total_pixels{};
  std::uint64_t reference_clamp_pixels{};
  std::uint64_t candidate_clamp_pixels{};
};

struct DisplayCurveResult {
  std::vector<DisplayCurvePoint> points;
};

// Decode two Adaptive HDR HEIC files once and compare their linear Display-P3
// reconstructions at each caller-supplied physical display headroom. This is
// intentionally a metric-only path: it does not write a second container or
// alter either input file.
//
// The files are read the way the input path reads them: float RGB, not clipped
// to [0,1] after the YCbCr conversion. A base pixel just below zero therefore
// counts in the clamp totals, where the earlier input path clipped it
// before the reconstruction and reported no clamps; MAE and MSE are measured
// against the unclipped base as well.
[[nodiscard]] DisplayCurveResult compare_gain_map_heic_curve(
    const std::filesystem::path& reference,
    const std::filesystem::path& candidate,
    const std::vector<float>& display_headroom_stops);

// Synchronous, repeatable native float rows. Calls are serialized on the
// encoding thread; the reader must fill the complete span before returning.
struct EncodingRows {
  std::uint32_t width{}, height{}, channels{};
  std::function<void(std::uint32_t y, std::span<float>)> read;
};
void write_sdr_jpeg_rows(const EncodingRows&, const PhotoMetadata&, int quality,
                         ColorGamut, const std::filesystem::path&);
void write_sdr_tiff_rows(const EncodingRows&, const PhotoMetadata&, ColorGamut,
                         const std::filesystem::path&);
void write_gain_map_jpeg_rows(const EncodingRows& base, const EncodingRows& codes,
    const GainMapMetadata&, const PhotoMetadata&, int quality, bool frame,
    const std::filesystem::path&);
[[nodiscard]] std::vector<std::uint8_t> encode_heic_rows(const EncodingRows& base,
    const EncodingRows& codes, const GainMapMetadata&, float headroom,
    const PhotoMetadata&, OutputEncoding, int quality, int depth, HevcPreset, bool frame = false);

namespace testing {
// Test seam for JPEG encoding: when set, every libjpeg progress callback calls
// `observer` on the encoding thread just before it checks for cancellation;
// `finishing` is true inside jpeg_finish_compress, where optimize_coding does
// the entropy coding. A test can request cancellation there. Not thread-safe;
// set it only while no encode runs.
void set_jpeg_progress_observer(void (*observer)(bool finishing));
}  // namespace testing

}  // namespace hyperdr
