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

#include <array>
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

// The four common 2x2 Bayer arrangements. The value is the sensor-coordinate
// arrangement, not the orientation of the rendered RGB image.
enum class BayerPattern {
  Unknown,
  RGGB,
  BGGR,
  GRBG,
  GBRG,
};

[[nodiscard]] const char* bayer_pattern_name(BayerPattern pattern);

// A calibrated, single-sample-per-site RAW mosaic. Samples are returned after
// LibRaw's metadata-driven black subtraction and are normalized by the
// post-black white level. Thus `black_level` is zero in this returned domain,
// `white_level` is the corresponding post-black saturation level, and values
// above 1.0 remain possible after an explicit digital gain.
struct RawMosaic {
  FloatImage samples;
  BayerPattern pattern{BayerPattern::Unknown};
  std::array<float, 4> black_level{};
  std::array<float, 4> white_level{};
  std::uint32_t bit_depth{};
  bool black_level_corrected{false};
};

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
  // Optional dcraw/LibRaw bad-pixel coordinate map. LibRaw interpolates the
  // listed sites from neighbouring CFA samples before demosaic.
  std::filesystem::path bad_pixel_map;
  // Optional dark-frame PGM accepted by LibRaw. It is subtracted before the
  // normal black-level correction.
  std::filesystem::path dark_frame;
  // Optional text LUT for sensor-code linearization. Format: one integer N,
  // followed by N output samples; values are code values unless all are in
  // [0,1], in which case they are interpreted as normalized code values.
  std::filesystem::path linearization_lut;
  // Optional text lens-shading map. Format: `width height channels` followed
  // by row-major gains; channels may be 1, 3 (RGB), or 4 (R,G1,B,G2).
  std::filesystem::path lens_shading_map;
  // Conservative opt-in detector for saturated hot pixels and zero/dead
  // pixels. It only replaces extreme outliers using same-CFA neighbours.
  bool auto_bad_pixel_correction{false};
  // Sensor-domain digital gain, applied after RAW calibration and retained as
  // scene-linear headroom. The normal renderer's --exposure is intentionally a
  // later photographic exposure decision.
  float digital_gain{1.0F};
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
  // Sensor-coordinate origins for the metadata request and the CFA-aligned
  // crop LibRaw actually used. Dimensions above/below are orientation-aware;
  // origins deliberately are not and are paired with metadata.orientation.
  std::uint32_t requested_crop_left{};
  std::uint32_t requested_crop_top{};
  std::uint32_t delivered_crop_left{};
  std::uint32_t delivered_crop_top{};
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
  // How far above diffuse white this input's *format* can carry detail, as a
  // linear multiple of 1.0. HLG is 1000/203, PQ up to 10000/203, a gain-map
  // input whatever its metadata declares, and everything else exactly 1.
  //
  // This is a property of the encoding, not a measurement of the pixels, and
  // the distinction is the point. A RAW routinely decodes to values above 1.0 --
  // that is white-balance normalisation headroom, which auto-exposure brings
  // back down -- and treating those as HDR highlights would make a scene-referred
  // input behave like a display-referred one. Consumers that need to know
  // whether an input is genuinely HDR must branch on this rather than on a
  // percentile of the image.
  float hdr_headroom{1.0F};
};

[[nodiscard]] DecodedImage decode_image(const std::filesystem::path& path,
                                        const RawDecodeOptions& options = {});

// Decode a Bayer RAW without demosaicing. This is the RAW-domain entry point
// for denoising, HDR fusion, low-light enhancement, and neural-network input.
// The returned raster is the visible sensor raster in sensor coordinates; it
// is not rotated or DefaultCrop-trimmed. Non-Bayer/X-Trans inputs are rejected
// rather than silently packed as if they were RGGB.
[[nodiscard]] RawMosaic decode_raw_mosaic(
    const std::filesystem::path& path, const RawDecodeOptions& options = {});

// Repack a calibrated Bayer raster to H/2 x W/2 x 4 in the fixed order
// R, Gr, Gb, B. The operation requires even dimensions and a known 2x2 CFA.
[[nodiscard]] FloatImage pack_bayer(const RawMosaic& mosaic);

// Ultra HDR JPEG/R input: applies the embedded gain map and returns the linear
// HDR rendition instead of the SDR primary image.
[[nodiscard]] bool is_ultrahdr_jpeg_file(const std::filesystem::path& path);
[[nodiscard]] DecodedImage decode_ultrahdr(const std::filesystem::path& path);

// AVIF input, including BT.2100 PQ and HLG renditions. The signature check is
// authoritative because AVIF and HEIF share the same container family.
[[nodiscard]] bool is_avif_file(const std::filesystem::path& path);
[[nodiscard]] DecodedImage decode_avif(const std::filesystem::path& path);

struct PreviewJpeg {
  std::vector<std::uint8_t> bytes;
  // Transport divisor for display-referred HDR inputs. Scene-referred RAW
  // remains unscaled and carries its photographic exposure separately.
  float scale{1.0F};
  float exposure_ev{0.0F};
};

// A bounded 8-bit compatibility thumbnail. The browser panel uses the native
// float `preview-frame` command instead; this remains a public CLI utility.
//
// `options` is the same RAW decode configuration the conversion uses, and it
// has to be: a preview built with different highlight recovery than the export
// is a preview of a different image, which is exactly how the panel came to
// show a picture that no setting could change. The caller owns the speed/detail
// trade-off through `options.half_size`.
// `apply_scene_exposure` is reserved for model inputs: it turns a RAW's
// scene-linear values into the exposure-normalized SDR domain expected by the
// external gain model. Browser previews keep it false and apply the returned
// exposure anchor in their linear renderer instead.
[[nodiscard]] PreviewJpeg encode_preview_jpeg(
    const std::filesystem::path& path, std::uint32_t max_edge = 2048,
    int quality = 85, const RawDecodeOptions& options = {},
    bool apply_scene_exposure = false);

}  // namespace hyperdr
