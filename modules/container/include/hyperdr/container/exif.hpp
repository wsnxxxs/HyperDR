#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace hyperdr {

// Decimal degrees as recorded by the camera. Exif stores these as
// degrees/minutes/seconds rationals plus a hemisphere reference, which is what
// make_minimal_exif writes; keeping the decimal form here avoids re-deriving
// the split in every producer.
struct GpsPosition {
  double latitude_degrees{};
  double longitude_degrees{};
  // Positive is above sea level. Absent when the camera recorded no altitude.
  std::optional<double> altitude_metres;
};

struct PhotoMetadata {
  std::string make{"SONY"};
  std::string model;
  std::string lens;
  std::string lens_make;
  std::string artist;
  std::string date_time;
  std::string copyright;
  // Provenance for the rendered file. Empty leaves the Software tag out.
  std::string software;
  std::uint16_t orientation{1};
  std::uint32_t iso{};
  double exposure_seconds{};
  double aperture{};
  double focal_length_mm{};
  double focal_length_35mm{};
  std::optional<GpsPosition> gps;
};

[[nodiscard]] std::vector<std::uint8_t> make_minimal_exif(const PhotoMetadata& metadata);
[[nodiscard]] std::string make_xmp(const PhotoMetadata& metadata, float headroom_stops);

// Reads the Orientation tag (IFD0, 0x0112) out of a TIFF/Exif block: the
// payload of a JPEG APP1 marker with its "Exif\0\0" prefix already removed, or
// a standalone Exif item from a container.
//
// Returns nullopt when the block is absent, truncated, malformed, or simply
// carries no Orientation, so a caller can distinguish "no tag" from an
// explicit orientation 1. Every offset is bounds-checked against `size`: this
// parses attacker-controlled bytes.
[[nodiscard]] std::optional<std::uint16_t> read_exif_orientation(
    const std::uint8_t* data, std::size_t size);

}  // namespace hyperdr

