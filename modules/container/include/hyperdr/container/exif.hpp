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

// `has_gain_map` controls the private Adaptive HDR declaration. PQ/HLG HEIC
// and AVIF carry a rendered HDR image, not an ISO 21496-1 gain map, and must
// not advertise themselves as gain-map containers merely because the same
// in-memory GainMapResult was used to render them.
[[nodiscard]] std::string make_xmp(const PhotoMetadata& metadata,
                                   float headroom_stops, bool has_gain_map);

// Parses the safe, portable subset emitted by make_minimal_exif from an Exif
// block. The block may start directly at its TIFF header, carry the JPEG
// "Exif\0\0" prefix, or use the HEIF four-byte TIFF-offset prefix. Unknown
// tags (including maker notes and embedded thumbnails) are intentionally
// ignored because they cannot be copied safely after the pixels change.
[[nodiscard]] std::optional<PhotoMetadata> read_photo_metadata(
    const std::uint8_t* data, std::size_t size);

// Finds the first Exif APP1 segment in a JPEG stream and parses it with the
// same bounds-checked reader. This is shared by plain JPEG and JPEG/R input.
[[nodiscard]] std::optional<PhotoMetadata> read_jpeg_photo_metadata(
    const std::uint8_t* data, std::size_t size);

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

