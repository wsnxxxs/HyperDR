#pragma once

// Packaging: an already-rendered SDR base plus gain plane, written to a file.
//
// After P7 the image processing lives in the Swift GPU render graph, so the
// engine no longer renders for export. Its export entry point takes the two
// planes the graph produced, quantizes the gain codes, hands them to the writer
// the converter has always used, verifies the result by decoding it, and
// reports what it wrote (docs/architecture/gpu-pipeline.md §3).
//
// Everything below the quantization is shared with `convert`: the same
// encoders, the same write-after checks, the same ISO 21496-1 metadata. This
// layer adds request validation, the gain codebook, and the report.

#include "hyperdr/codec/encoding.hpp"
#include "hyperdr/image/color.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>

namespace hyperdr {

// One caller-owned plane of interleaved float32 samples. `row_bytes` is zero
// for tightly packed rows and otherwise the distance between row starts, so a
// caller can hand over a strided buffer without repacking it.
struct PackagePlane {
  const float* data{};
  std::size_t row_bytes{};
  // Bytes the caller's buffer actually holds. Zero means "the caller
  // guarantees the rows are complete"; a non-zero value is checked against
  // `row_bytes * height`, so an undersized buffer is refused instead of read
  // past its end.
  std::size_t size{};
  std::uint32_t width{};
  std::uint32_t height{};
  std::uint32_t channels{};
};

// The gain plane and the ISO 21496-1 parameters that describe it.
//
// The samples are log2 stops over the SDR white of the base, at the same pixel
// grid as the base. `working_gamut` names the space the ratios were measured
// in; only the base's own space, "display-p3", is accepted, because none of the
// writers converts a grid between gamuts.
struct PackageGain {
  PackagePlane plane;
  std::array<float, 3> base_offset{};
  std::array<float, 3> alternate_offset{};
  float base_headroom{};
  float alternate_headroom{};
  std::string working_gamut{"display-p3"};
};

struct PackageRequest {
  std::filesystem::path output;
  OutputEncoding encoding{OutputEncoding::Adaptive};
  int quality{90};
  // Base bit depth for Adaptive HEIC; 8 or 10.
  int depth{8};
  HevcPreset hevc_preset{HevcPreset::Slow};
  // SDR JPEG/TIFF only; the format default applies when unset.
  std::optional<ColorGamut> gamut;
  bool verify{true};
  bool overwrite{false};
  // Required. Three linear extended Display P3 channels, SDR white = 1.0.
  const PackagePlane* sdr{};
  // Optional. Required by the gain-map and BT.2100 formats, ignored by the SDR
  // formats, which store no gain.
  const PackageGain* gain{};
  // Optional serialized Exif block. The writer re-emits the safe portable
  // subset, with orientation 1 because the planes are expected upright.
  const std::uint8_t* exif{};
  std::size_t exif_size{};
};

// Packages one file and returns the report document (`hyperdr.package/v1`).
//
// Throws UnsupportedFormat for a format that cannot carry this pair (a
// three-channel gain map in Adaptive HEIC, a gain plane for a format that has
// no HDR rendition, a gain above the declared alternate headroom), and
// invalid_argument for a malformed request.
[[nodiscard]] std::string package_image(const PackageRequest& request);

}  // namespace hyperdr
