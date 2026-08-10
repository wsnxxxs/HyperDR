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
  // Empty means "the input did not say". It used to default to "SONY" and the
  // raster decoders overwrote it with the container's name, so a converted HEIC
  // was exported claiming a camera manufacturer of "HEIC". Every producer now
  // either reads a real value out of the input's Exif or leaves this blank, and
  // a blank one writes no Make tag at all.
  std::string make;
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

// What an input's Exif block says about the photograph.
//
// The camera, the lens and the capture settings are read, not invented: every
// field a producer cannot find is left at its default, and `orientation` is
// nullopt rather than 1 when the block carries no Orientation tag, so a caller
// can tell "no tag" from an explicit "already upright". `metadata.orientation`
// mirrors it when one is present.
//
// The block may be the payload of a JPEG APP1 marker, a HEIF `Exif` item with
// its four-byte offset prefix still attached, or libavif's Exif payload: the
// reader finds the TIFF byte-order mark within a short leading window rather
// than making each caller know its container's preamble.
//
// Every offset is bounds-checked against `size` and nothing here throws: this
// parses attacker-controlled bytes, and a malformed block costs a field rather
// than the conversion.
struct ExifRead {
  PhotoMetadata metadata;
  std::optional<std::uint16_t> orientation;
};

[[nodiscard]] ExifRead read_exif(const std::uint8_t* data, std::size_t size);

// Just the Orientation tag, for callers that normalise rotation and want
// nothing else. A thin call into read_exif, so there is one parser.
[[nodiscard]] std::optional<std::uint16_t> read_exif_orientation(
    const std::uint8_t* data, std::size_t size);

}  // namespace hyperdr

