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
#include "hyperdr/image/orientation.hpp"

#include <cmath>
#include <cstdint>
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
  image.linear_p3 = apply_exif_orientation(std::move(image.linear_p3), orientation);
  if (exif_orientation_transposes(orientation)) {
    std::swap(image.decode.target_width, image.decode.target_height);
    std::swap(image.decode.decoded_width, image.decode.decoded_height);
  }
  image.metadata.orientation = 1;
}

}  // namespace hyperdr::codec
