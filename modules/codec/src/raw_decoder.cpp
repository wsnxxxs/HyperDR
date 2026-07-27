#include "hyperdr/image/color.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/codec/encoders.hpp"
#include "hyperdr/codec/image_source.hpp"
#include "internal/budget.hpp"
#include "internal/raw.hpp"
#include "hyperdr/foundation/version.hpp"

#include <libraw/libraw.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstring>
#include <ctime>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>

namespace hyperdr {
namespace {

void check_raw(int code, const char* operation) {
  // LibRaw uses negative values for its own enum and positive values for errno.
  // Both LIBRAW_UNSUFFICIENT_MEMORY and the system ENOMEM therefore mean the
  // same thing even though their signs differ.
  if (code == LIBRAW_UNSUFFICIENT_MEMORY || code == ENOMEM) {
    throw RawMemoryError(std::string(operation) +
                         ": insufficient memory for requested-resolution RAW processing");
  }
  if (code != LIBRAW_SUCCESS) {
    throw std::runtime_error(std::string(operation) + ": " +
                             libraw_strerror(code));
  }
}

std::string safe_string(const char* value) { return value ? std::string(value) : std::string{}; }

constexpr std::uint64_t kEstimatedPipelineBytesPerPixel = 32;
constexpr std::uint64_t kSystemReserveBytes =
    512ULL * 1024ULL * 1024ULL;

std::uint64_t estimated_pipeline_bytes(std::uint64_t width,
                                       std::uint64_t height) {
  // The overlapping LibRaw mosaic (4 x uint16), processed RGB
  // (3 x uint16), and linear working image (3 x float) need 26 bytes/pixel.
  // Use 32 bytes/pixel to leave room for allocator and row overhead before
  // admitting the RAW decode.
  const auto pixels = width * height;  // already bounded by raw_input_budget_ok
  return pixels * kEstimatedPipelineBytesPerPixel;
}

void check_raw_memory_admission(std::uint64_t width, std::uint64_t height) {
  const auto required = estimated_pipeline_bytes(width, height);
  const auto available = available_memory_bytes();
  if (available != 0 &&
      (available <= kSystemReserveBytes ||
       required > available - kSystemReserveBytes)) {
    const auto mib = [](std::uint64_t bytes) {
      return (bytes + (1ULL << 20U) - 1U) >> 20U;
    };
    throw RawMemoryError(
        "insufficient memory for requested RAW decode " +
        std::to_string(width) + "x" + std::to_string(height) +
        " (approximately " + std::to_string(mib(required)) +
        " MiB required, " + std::to_string(mib(available)) +
        " MiB currently available)");
  }
}

}  // namespace

namespace codec {

DecodedImage decode_raw(const std::filesystem::path& path,
                        const RawDecodeOptions& options) {
  LibRaw raw;
  // Parameters that affect camera WB/matrix selection must be configured before
  // open_file(), when LibRaw copies camera calibration data into the pipeline.
  auto& params = raw.imgdata.params;
  params.use_camera_wb = 1;
  params.use_auto_wb = 0;
  params.use_camera_matrix = 1;
  params.no_auto_bright = 1;
  params.output_bps = 16;
  params.half_size = options.half_size ? 1 : 0;
  // ProPhoto's matrix rows sum to one, so neutral highlights fit in LibRaw's
  // 16-bit output. XYZ (output_color=5) has a 1.0888 Z row sum and therefore
  // clips neutral highlights in only that channel before float conversion.
  params.output_color = 4;
  params.gamm[0] = 1.0;
  params.gamm[1] = 1.0;
  switch (options.highlight_recovery) {
    case HighlightRecovery::Clip: params.highlight = 0; break;
    case HighlightRecovery::Unclip: params.highlight = 1; break;
    case HighlightRecovery::Blend: params.highlight = 2; break;
    case HighlightRecovery::Reconstruct: params.highlight = 3; break;
  }
  // Correct channel overflow before demosaic; this is specifically intended to
  // prevent artefacts such as magenta clouds.
  params.adjust_maximum_thr = 0.75F;
  check_raw(raw.open_file(path.c_str()), "LibRaw open");

  // LibRaw's only cheap RAW reduction must be selected before unpack(). It is
  // an explicit preview choice: a full export is a full-resolution contract,
  // so this decoder must never turn a successful 60 MP export into 15 MP merely
  // because an internal working-set estimate was crossed.
  const auto& sizes = raw.imgdata.sizes;
  const std::uint64_t full_width = sizes.width;
  const std::uint64_t full_height = sizes.height;
  if (!raw_input_budget_ok(full_width, full_height)) {
    throw std::runtime_error(
        "RAW image " + std::to_string(full_width) + "x" +
        std::to_string(full_height) +
        " exceeds the supported 240869376-pixel input limit");
  }
  const std::uint64_t decode_width =
      params.half_size ? (full_width + 1U) / 2U : full_width;
  const std::uint64_t decode_height =
      params.half_size ? (full_height + 1U) / 2U : full_height;
  check_raw_memory_admission(decode_width, decode_height);
  const bool swaps_axes = (sizes.flip & 4) != 0;
  DecodeInfo decode;
  decode.sensor_width = sizes.raw_width ? sizes.raw_width : sizes.width;
  decode.sensor_height = sizes.raw_height ? sizes.raw_height : sizes.height;
  decode.target_width = static_cast<std::uint32_t>(
      swaps_axes ? full_height : full_width);
  decode.target_height = static_cast<std::uint32_t>(
      swaps_axes ? full_width : full_height);
  decode.resolution_reduced = params.half_size != 0;
  const auto mark_degraded = [&](std::string_view reason) {
    decode.degraded = true;
    decode.degradation_reasons.emplace_back(reason);
  };
  // With highlight recovery enabled dcraw normalises by the largest WB
  // multiplier instead of the smallest, darkening the whole frame by
  // dmin/dmax. cam_mul is the camera/as-shot WB that scale_colors uses for this
  // normalisation; pre_mul already includes colour-calibration scaling and
  // over-corrects this A7R V by about 0.06 EV. Capture cam_mul before
  // dcraw_process() mutates the colour state and restore the exposure later in
  // float, where HDR values may exceed 1.0 without clipping.
  float exposure_gain = 1.0F;
  if (options.highlight_recovery != HighlightRecovery::Clip) {
    float dmin = std::numeric_limits<float>::max();
    float dmax = 0.0F;
    for (const float multiplier : raw.imgdata.color.cam_mul) {
      if (!(multiplier > 0.0F) || !std::isfinite(multiplier)) continue;
      dmin = std::min(dmin, multiplier);
      dmax = std::max(dmax, multiplier);
    }
    if (dmin > 0.0F && dmax > dmin) exposure_gain = dmax / dmin;
  }

  check_raw(raw.unpack(), "LibRaw unpack");
#if defined(LIBRAW_VERSION) && defined(LIBRAW_MAKE_VERSION)
#if LIBRAW_VERSION >= LIBRAW_MAKE_VERSION(0, 21, 0)
  // raw_inset_crops is expressed in the sensor coordinate system. Promote the
  // camera's DefaultCrop to LibRaw's margins before demosaic so half-size,
  // orientation and CFA alignment are all handled by LibRaw itself.
  const auto& default_crop = raw.imgdata.sizes.raw_inset_crops[0];
  decode.default_crop_present =
      default_crop.cleft != 0xffff && default_crop.ctop != 0xffff &&
      default_crop.cwidth > 0 && default_crop.cheight > 0;
  if (decode.default_crop_present) {
    decode.target_width =
        swaps_axes ? default_crop.cheight : default_crop.cwidth;
    decode.target_height =
        swaps_axes ? default_crop.cwidth : default_crop.cheight;
    // maxcrop is passed explicitly even though 0.55 is the current LibRaw
    // default: the rejection path is covered by a test, so inheriting the
    // default would let a LibRaw upgrade change both the behaviour and the
    // test's meaning at once, with a failure message pointing elsewhere.
    // Returns adjindex + 1, so 1 -- not merely non-zero -- is crops[0].
    if (raw.adjust_to_raw_inset_crop(1, 0.55F) != 1) {
      // The maxcrop guard rejected the metadata. Continue with LibRaw's
      // visible area, but leave target_* as the unmet request and say so, so
      // no consumer reads decoded_*/target_* as a scale ratio.
      decode.target_dimensions_applied = false;
      mark_degraded("default_crop_rejected");
    }
  }
#endif
#endif
  check_raw(raw.dcraw_process(), "LibRaw demosaic");
  int error = 0;
  std::unique_ptr<libraw_processed_image_t, decltype(&LibRaw::dcraw_clear_mem)>
      processed(raw.dcraw_make_mem_image(&error), &LibRaw::dcraw_clear_mem);
  check_raw(error, "LibRaw memory image");
  if (!processed) {
    throw RawMemoryError(
        "LibRaw memory image: insufficient memory for processed RAW pixels");
  }
  if (processed->type != LIBRAW_IMAGE_BITMAP || processed->colors < 3 ||
      processed->bits != 16)
    throw std::runtime_error("LibRaw did not return a 16-bit RGB bitmap");

  DecodedImage result;
  decode.decoded_width = processed->width;
  decode.decoded_height = processed->height;
  result.decode = std::move(decode);
  result.linear_p3 = FloatImage(processed->width, processed->height, 3);
  const auto* pixels = reinterpret_cast<const std::uint16_t*>(processed->data);
  parallel_for_rows(processed->height, [&](const std::uint32_t y) {
    const auto row_start = static_cast<std::size_t>(y) * processed->width;
    for (std::uint32_t x = 0; x < processed->width; ++x) {
      const auto output_index = row_start + x;
      const auto input_index =
          output_index * processed->colors;
      const float r = pixels[input_index] / 65535.0F * exposure_gain;
      const float g = pixels[input_index + 1] / 65535.0F * exposure_gain;
      const float b = pixels[input_index + 2] / 65535.0F * exposure_gain;
      const auto p3 = prophoto_to_linear_p3(r, g, b);
      result.linear_p3.pixels[output_index * 3] = p3[0];
      result.linear_p3.pixels[output_index * 3 + 1] = p3[1];
      result.linear_p3.pixels[output_index * 3 + 2] = p3[2];
    }
  });

  const auto& other = raw.imgdata.other;
  result.metadata.make = safe_string(raw.imgdata.idata.make);
  result.metadata.model = safe_string(raw.imgdata.idata.model);
  result.metadata.lens = safe_string(raw.imgdata.lens.Lens);
  result.metadata.lens_make = safe_string(raw.imgdata.lens.LensMake);
  result.metadata.artist = safe_string(other.artist);
  result.metadata.software = std::string("HyperDR ") + kVersion;
  if (raw.imgdata.lens.makernotes.FocalLengthIn35mmFormat > 0) {
    result.metadata.focal_length_35mm =
        static_cast<double>(raw.imgdata.lens.makernotes.FocalLengthIn35mmFormat);
  }
  const auto capture_value = [](double value) -> std::optional<float> {
    if (!(std::isfinite(value) && value > 0.0 &&
          value <= static_cast<double>(std::numeric_limits<float>::max()))) {
      return std::nullopt;
    }
    return static_cast<float>(value);
  };
  result.capture.iso = capture_value(other.iso_speed);
  result.capture.exposure_time_seconds = capture_value(other.shutter);
  result.capture.aperture_f_number = capture_value(other.aperture);
  if (result.capture.iso) {
    result.metadata.iso = static_cast<std::uint32_t>(std::min<double>(
        *result.capture.iso, std::numeric_limits<std::uint32_t>::max()));
  }
  result.metadata.exposure_seconds = result.capture.exposure_time_seconds.value_or(0.0F);
  result.metadata.aperture = result.capture.aperture_f_number.value_or(0.0F);
  result.metadata.focal_length_mm = other.focal_len;
  if (other.timestamp > 0) {
    std::tm time{};
    localtime_s(&time, &other.timestamp);
    char buffer[32]{};
    if (std::strftime(buffer, sizeof(buffer), "%Y:%m:%d %H:%M:%S", &time)) result.metadata.date_time = buffer;
  }
#if defined(LIBRAW_VERSION) && defined(LIBRAW_MAKE_VERSION)
#if LIBRAW_VERSION >= LIBRAW_MAKE_VERSION(0, 19, 0)
  // Only a fix the camera actually parsed is carried through; a zeroed struct
  // would otherwise be written out as a valid position off the coast of Africa.
  const auto& gps = other.parsed_gps;
  if (gps.gpsparsed != 0) {
    const auto to_degrees = [](const float parts[3]) {
      return static_cast<double>(parts[0]) + static_cast<double>(parts[1]) / 60.0 +
             static_cast<double>(parts[2]) / 3600.0;
    };
    GpsPosition position;
    position.latitude_degrees = to_degrees(gps.latitude);
    position.longitude_degrees = to_degrees(gps.longitude);
    if (gps.latref == 'S' || gps.latref == 's') {
      position.latitude_degrees = -position.latitude_degrees;
    }
    if (gps.longref == 'W' || gps.longref == 'w') {
      position.longitude_degrees = -position.longitude_degrees;
    }
    if (std::isfinite(gps.altitude) && gps.altitude != 0.0F) {
      position.altitude_metres =
          gps.altref != 0 ? -static_cast<double>(gps.altitude)
                          : static_cast<double>(gps.altitude);
    }
    if (std::isfinite(position.latitude_degrees) &&
        std::isfinite(position.longitude_degrees) &&
        std::abs(position.latitude_degrees) <= 90.0 &&
        std::abs(position.longitude_degrees) <= 180.0) {
      result.metadata.gps = position;
    }
  }
#endif
#endif
  // LibRaw applies the sensor orientation while rendering, so the encoded pixels are top-left.
  result.metadata.orientation = 1;
  return result;
}

}  // namespace codec
}  // namespace hyperdr
