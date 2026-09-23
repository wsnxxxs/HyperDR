#pragma once

// Putting what an input's Exif says onto a decoded image.
//
// Four decoders need this and they must agree, because the renderer cannot tell
// them apart: `capture` drives EV100 and the ISO terms that weigh the gain map
// against noise, and `metadata` is what gets written back out. A decoder that
// filled one and not the other, or that rotated the pixels without correcting
// the dimensions it reports, would be a per-format difference in the rendered
// photograph -- which is exactly what this module exists to prevent.

#include "hyperdr/codec/image_source.hpp"
#include "hyperdr/container/exif.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/image/orientation.hpp"

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <utility>

namespace hyperdr::codec {

// Copies the photograph's description onto `image` without letting it
// contradict the pixels: orientation is normalised into the raster by
// `normalize_orientation`, so the result always declares orientation 1.
inline void apply_exif(DecodedImage& image, const ExifRead& exif) {
  image.metadata = exif.metadata;
  image.metadata.orientation = 1;
  const auto positive = [](double value) -> std::optional<float> {
    if (!(value > 0.0) || !std::isfinite(value)) return std::nullopt;
    return static_cast<float>(value);
  };
  image.capture.iso =
      image.metadata.iso != 0
          ? std::optional<float>(static_cast<float>(image.metadata.iso))
          : std::nullopt;
  image.capture.exposure_time_seconds = positive(image.metadata.exposure_seconds);
  image.capture.aperture_f_number = positive(image.metadata.aperture);
  // The research level estimator reads the capture exactly as the camera wrote
  // it, so these three come from `metadata.capture` -- the presence-preserving
  // copy -- rather than from the plain doubles, whose zero default cannot say
  // whether the tag was there. A recorded 0 EV is kept as a value.
  const auto recorded = [](const std::optional<double>& value) -> std::optional<float> {
    if (!value.has_value() || !std::isfinite(*value)) return std::nullopt;
    return static_cast<float>(*value);
  };
  image.capture.exposure_bias_ev = recorded(image.metadata.capture.exposure_bias_ev);
  // The two length fields follow the estimator's own presence rule, which treats
  // a zero as unknown because Exif defines it that way; the two sides must agree
  // or the same photograph would be complete in one and absent in the other.
  const auto length = [](const std::optional<double>& value) -> std::optional<float> {
    if (!value.has_value() || !std::isfinite(*value) || *value == 0.0) return std::nullopt;
    return static_cast<float>(*value);
  };
  image.capture.focal_length_mm = length(image.metadata.capture.focal_length_mm);
  image.capture.focal_length_35mm = length(image.metadata.capture.focal_length_35mm);
}

// The capture vector for a level model, read from the file's own Exif.
//
// A decoder that filled `capture` from its decoding library instead would make
// the same photograph a complete input in one container and an incomplete one in
// another, and would lose the presence information the model's fallback rule
// turns on: LibRaw reports no exposure compensation at all rather than a zero,
// and no 35 mm-equivalent focal length. Only the leading block is read -- every
// format this build opens keeps IFD0 and the Exif IFD near the front, and
// re-reading a 60 MB RAW to recover six numbers would cost more than the decode.
//
// `metadata.capture` is replaced wholesale rather than merged: a partial read
// must leave the fields it did not find absent, not inherit a neighbouring
// decoder's guess.
inline void apply_capture_parameters_from_file(
    DecodedImage& image, const std::filesystem::path& path,
    std::size_t prefix_bytes = 1U << 20U) {
  const auto prefix = read_binary_prefix(path, prefix_bytes);
  if (prefix.empty()) return;
  const auto exif = read_exif(prefix.data(), prefix.size());
  image.metadata.capture = exif.metadata.capture;
  const auto recorded = [](const std::optional<double>& value) -> std::optional<float> {
    if (!value.has_value() || !std::isfinite(*value)) return std::nullopt;
    return static_cast<float>(*value);
  };
  image.capture.exposure_bias_ev = recorded(exif.metadata.capture.exposure_bias_ev);
  // The two length fields keep the same zero-means-unknown rule the estimator
  // uses, so a container that wrote a zero and one that omitted the tag reach
  // the same conclusion.
  const auto length = [](const std::optional<double>& value) -> std::optional<float> {
    if (!value.has_value() || !std::isfinite(*value) || *value == 0.0) return std::nullopt;
    return static_cast<float>(*value);
  };
  image.capture.focal_length_mm = length(exif.metadata.capture.focal_length_mm);
  image.capture.focal_length_35mm = length(exif.metadata.capture.focal_length_35mm);
}

// Rotates the raster so the stored orientation becomes 1, and brings the
// reported geometry with it.
//
// `DecodeInfo` documents target_* and decoded_* as post-orientation, but the
// JPEG path rotated the pixels and left both describing the stored raster, so a
// portrait phone photo reported its dimensions the wrong way round in the run
// report while `width`/`height` -- taken from the rotated image -- disagreed.
// sensor_* is deliberately left alone: it is the shape of the readout, and a
// portrait frame really does come off a landscape sensor.
inline void normalize_orientation(DecodedImage& image, std::uint16_t orientation) {
  if (orientation == 1 || orientation < 1 || orientation > 8) return;
  image.transform_planes([&](FloatImage plane) {
    return apply_exif_orientation(std::move(plane), orientation);
  });
  if (exif_orientation_transposes(orientation)) {
    std::swap(image.decode.target_width, image.decode.target_height);
    std::swap(image.decode.decoded_width, image.decode.decoded_height);
  }
  image.metadata.orientation = 1;
}

}  // namespace hyperdr::codec
