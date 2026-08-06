#pragma once

// Decoding any supported input into the pipeline's one working space: linear
// Display P3, 32-bit float, unbounded above 1.
//
// ARW/DNG go through LibRaw; JPEG, PNG and HEIC through their own codecs; an
// Ultra HDR JPEG is read through its gain map rather than through its
// backward-compatible SDR primary, so re-exporting one does not discard the
// captured highlight range. Everything downstream sees one image type and does
// not know which path produced it.

#include "hyperdr/container/exif.hpp"
#include "hyperdr/image/image.hpp"
#include "hyperdr/look/options.hpp"

#include <optional>
#include <stdexcept>
#include <string_view>

#include <cstdint>
#include <filesystem>
#include <vector>
#include <string>

namespace hyperdr {

class RawMemoryError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

enum class HighlightRecovery {
  Clip,
  Unclip,
  Blend,
  Reconstruct,
};

[[nodiscard]] const char* highlight_recovery_name(HighlightRecovery mode);
[[nodiscard]] std::optional<HighlightRecovery> highlight_recovery_from_name(
    std::string_view name);

struct RawDecodeOptions {
  // LibRaw's unclip mode can leave strongly magenta clipped highlights when
  // sensor channels saturate at different levels. Blend is the conservative
  // default: it removes false colour while retaining highlight luminance.
  HighlightRecovery highlight_recovery{HighlightRecovery::Blend};
  // LibRaw's fixed 1/2-per-axis demosaic, used only by fast preview callers.
  // Full export callers leave this false; the decoder never enables it
  // automatically in response to an internal memory estimate.
  bool half_size{false};
  // When an external canonical gain grid is supplied, decode only the SDR
  // base of an embedded Apple/Ultra HDR container. Applying the embedded map
  // first would double-count the same gain before the external grid is used.
  bool ignore_embedded_gain_map{false};
};

struct DecodeInfo {
  // The stored RAW sensor raster, including margins when the format exposes
  // them. These are sensor coordinates and are deliberately *not* rotated by
  // the capture orientation, unlike target_* and decoded_*: this is the shape
  // of the physical readout, so a portrait frame reports a landscape sensor.
  // Raster inputs use their decoded dimensions here.
  std::uint32_t sensor_width{};
  std::uint32_t sensor_height{};
  // The full-resolution photographic area requested by DefaultCrop, after
  // orientation. When no DefaultCrop is present this is LibRaw's visible area.
  //
  // This is the DefaultCrop raster only. It does not include the pixel-aspect
  // or Fuji-SuperCCD geometric stretch that LibRaw applies in
  // adjust_sizes_info_only() *before* the orientation swap, so it disagrees
  // with decoded_* for any input whose pixel_aspect != 1 or that carries Fuji
  // data -- which a DNG container can, not just a RAF.
  std::uint32_t target_width{};
  std::uint32_t target_height{};
  // Pixels actually returned by the decoder, before any preview resampling.
  std::uint32_t decoded_width{};
  std::uint32_t decoded_height{};
  // Structural resolution state, set from what the decoder actually did rather
  // than inferred by comparing dimensions that may include pixel-aspect or
  // SuperCCD geometry. Strict exports reject true; previews may accept it.
  bool resolution_reduced{false};
  // The one control predicate, and the only field a consumer may branch on to
  // decide whether target_* describes geometry the decode actually delivered.
  // False only when a recorded DefaultCrop was rejected, leaving target_* as
  // the request rather than the result -- decoded_*/target_* is not a scale
  // ratio in that case.
  bool target_dimensions_applied{true};
  // Descriptive only: whether the input carried a DefaultCrop at all. Present
  // so "no crop recorded" and "crop applied" stay distinguishable without
  // reading the reasons below.
  bool default_crop_present{false};
  bool degraded{false};
  // Diagnostics and presentation only. Nothing may branch on these strings:
  // adding a reason must never change a consumer's behaviour, which is what
  // target_dimensions_applied and default_crop_present are for.
  std::vector<std::string> degradation_reasons;
};

struct DecodedImage {
  FloatImage linear_p3;
  PhotoMetadata metadata;
  CaptureMetadata capture;
  DecodeInfo decode;
};

[[nodiscard]] DecodedImage decode_image(const std::filesystem::path& path,
                                        const RawDecodeOptions& options = {});

// Ultra HDR JPEG/R input: applies the embedded gain map and returns the linear
// HDR rendition instead of the SDR primary image.
[[nodiscard]] bool is_ultrahdr_jpeg_file(const std::filesystem::path& path);
[[nodiscard]] DecodedImage decode_ultrahdr(const std::filesystem::path& path);

// A bounded 8-bit preview of any supported input, for the browser panel.
//
// `options` is the same RAW decode configuration the conversion uses, and it
// has to be: a preview built with different highlight recovery than the export
// is a preview of a different image, which is exactly how the panel came to
// show a picture that no setting could change. The caller owns the speed/detail
// trade-off through `options.half_size`.
[[nodiscard]] std::vector<std::uint8_t> encode_preview_jpeg(
    const std::filesystem::path& path, std::uint32_t max_edge = 2048,
    int quality = 85, const RawDecodeOptions& options = {});

}  // namespace hyperdr
