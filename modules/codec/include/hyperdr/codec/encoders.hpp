#pragma once

// Writing a rendered image out, and reading it back to prove it decodes.
//
// Every conversion verifies its own output by default. An encoder that produces
// a structurally valid file no decoder will open is the failure mode this
// project most needs to catch before the user does, and the only reliable check
// is to decode what was just written.

#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/gainmap/types.hpp"
#include "hyperdr/image/color.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <vector>

namespace hyperdr {

// Display P3 SDR base plus an ISO 21496-1 gain map, related by a `tmap` derived
// item. `depth` selects the base image's bit depth; the gain map is always 8-bit.
[[nodiscard]] std::vector<std::uint8_t> encode_adaptive_heic(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    int depth, HevcPreset preset = HevcPreset::Slow);

// Backward-compatible JPEG/R, carrying both Ultra HDR v1 XMP and ISO 21496-1
// metadata. Requires an 8-bit base.
[[nodiscard]] std::vector<std::uint8_t> encode_ultrahdr_jpeg(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality);

// API3: compute RGB gain against the decoded final JPEG, reusing its compressed
// base. HDR is linear Display P3, white 1 = 203 nits, with matching raster size
// and orientation. The JPEG must use sRGB transfer and the declared gamut (or
// a matching supported ICC profile). No PQ/HLG file is needed.
// XMP compatibility computes gain in the base gamut: an sRGB base can clip HDR
// colours outside sRGB. Prefer a P3 base for P3 HDR. JPEG markers are rewritten;
// the compressed primary image is retained, not the complete file byte-for-byte.
[[nodiscard]] std::vector<std::uint8_t> encode_ultrahdr_jpeg(
    const FloatImage& hdr, const std::vector<std::uint8_t>& sdr_jpeg,
    ColorGamut sdr_gamut, float headroom_stops, int gain_quality = 95);
[[nodiscard]] std::vector<std::uint8_t> encode_ultrahdr_jpeg(
    const PhotoRenditions& images, const PhotoMetadata& metadata, int quality);

// Header-only inspection; no full HDR allocation or decode. Gain ranges are
// log2 stops, independently of the display capacity. Arrays describe RGB.
struct UltraHdrInfo {
  std::uint32_t width{}, height{}, gain_width{}, gain_height{};
  std::array<float, 3> gain_min{}, gain_max{}, gamma{};
  float headroom_stops{};
};
[[nodiscard]] UltraHdrInfo probe_ultrahdr_jpeg(const std::vector<std::uint8_t>& bytes);

// Compatibility overloads for callers that already own gain-map renditions.
// The application uses the PhotoRenditions overloads below for direct HDR.
[[nodiscard]] std::vector<std::uint8_t> encode_hdr_heic(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    HdrEncoding encoding, HevcPreset preset = HevcPreset::Slow);
[[nodiscard]] std::vector<std::uint8_t> encode_avif(
    const GainMapResult& images, const PhotoMetadata& metadata, int quality,
    HdrEncoding encoding);


[[nodiscard]] std::vector<std::uint8_t> encode_sdr_jpeg(
    const FloatImage& image, const PhotoMetadata& metadata, int quality);
void verify_sdr_jpeg(const std::vector<std::uint8_t>& bytes);
[[nodiscard]] std::vector<std::uint8_t> encode_hdr_heic(
    const PhotoRenditions& images, const PhotoMetadata& metadata, int quality, HdrEncoding encoding,
    HevcPreset preset = HevcPreset::Slow);
[[nodiscard]] std::vector<std::uint8_t> encode_avif(
    const PhotoRenditions& images, const PhotoMetadata& metadata, int quality, HdrEncoding encoding);

// Decode-verification. Each throws with a specific reason on failure.
void verify_heic_decodable(const std::vector<std::uint8_t>& bytes);
void verify_heic_decodable(const std::vector<std::uint8_t>& bytes,
                           HdrEncoding encoding);
void verify_heic_decodable(const std::filesystem::path& input);
void verify_ultrahdr_jpeg(const std::vector<std::uint8_t>& bytes);
void verify_ultrahdr_jpeg(const std::filesystem::path& input);
void verify_avif_decodable(const std::vector<std::uint8_t>& bytes);

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
[[nodiscard]] DisplayCurveResult compare_gain_map_heic_curve(
    const std::filesystem::path& reference,
    const std::filesystem::path& candidate,
    const std::vector<float>& display_headroom_stops);

}  // namespace hyperdr
