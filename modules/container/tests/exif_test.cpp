#include "hyperdr/container/exif.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void test_exif() {
  hyperdr::PhotoMetadata metadata;
  metadata.make = "Sony";
  metadata.model = "ILCE-7RM5";
  metadata.lens = "FE 24-70mm F2.8 GM II";
  metadata.date_time = "2026:07:16 12:34:56";
  metadata.iso = 400;
  metadata.exposure_seconds = 1.0 / 125.0;
  metadata.aperture = 2.8;
  metadata.focal_length_mm = 35.0;
  const auto exif = hyperdr::make_minimal_exif(metadata);
  require(exif.size() > 32 && exif[0] == 'I' && exif[1] == 'I', "Exif TIFF construction failed");
  const auto xmp = hyperdr::make_xmp(metadata, 2.5F, true);
  require(xmp.find("ISO-21496-1:2025") != std::string::npos, "XMP marker missing");
  const auto rendered_xmp = hyperdr::make_xmp(metadata, 2.5F, false);
  require(rendered_xmp.find("ISO-21496-1") == std::string::npos &&
              rendered_xmp.find("AdaptiveHDR") == std::string::npos &&
              rendered_xmp.find("RenderedHDR='true'") != std::string::npos,
          "rendered HDR XMP must not claim that a gain map is present");

  metadata.iso = 102400;
  const auto high_iso_exif = hyperdr::make_minimal_exif(metadata);
  const std::array<std::uint8_t, 12> iso_sentinel{
      0x27, 0x88, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
      0xFF, 0xFF, 0x00, 0x00};
  require(std::search(high_iso_exif.begin(), high_iso_exif.end(),
                      iso_sentinel.begin(), iso_sentinel.end()) !=
              high_iso_exif.end(),
          "high ISO Exif sentinel missing");
  const auto high_iso_xmp = hyperdr::make_xmp(metadata, 2.5F, true);
  require(high_iso_xmp.find("<rdf:li>102400</rdf:li>") != std::string::npos,
          "high ISO value missing from XMP sequence");
}

void test_portable_metadata_round_trip() {
  hyperdr::PhotoMetadata source;
  source.make = "Camera & Co";
  source.model = "Model X";
  source.lens = "35mm Prime";
  source.lens_make = "Lens Co";
  source.artist = "Photographer";
  source.copyright = "Copyright 2026";
  source.date_time = "2026:08:12 10:11:12";
  source.orientation = 6;
  source.iso = 800;
  source.exposure_seconds = 1.0 / 250.0;
  source.aperture = 4.0;
  source.focal_length_mm = 35.0;
  source.focal_length_35mm = 35.0;
  source.gps = hyperdr::GpsPosition{-27.4698, 153.0251, -4.5};

  const auto tiff = hyperdr::make_minimal_exif(source);
  const auto parsed = hyperdr::read_photo_metadata(tiff.data(), tiff.size());
  require(parsed.has_value(), "generated Exif must be parseable");
  require(parsed->make == source.make && parsed->model == source.model &&
              parsed->lens == source.lens &&
              parsed->lens_make == source.lens_make &&
              parsed->artist == source.artist &&
              parsed->copyright == source.copyright &&
              parsed->date_time == source.date_time,
          "portable Exif strings did not round trip");
  require(parsed->orientation == 6 && parsed->iso == 800 &&
              std::abs(parsed->exposure_seconds - source.exposure_seconds) < 1.0e-5 &&
              std::abs(parsed->aperture - source.aperture) < 1.0e-5 &&
              std::abs(parsed->focal_length_mm - source.focal_length_mm) < 1.0e-5 &&
              parsed->focal_length_35mm == source.focal_length_35mm,
          "portable Exif numeric fields did not round trip");
  require(parsed->gps.has_value() &&
              std::abs(parsed->gps->latitude_degrees -
                       source.gps->latitude_degrees) < 1.0e-5 &&
              std::abs(parsed->gps->longitude_degrees -
                       source.gps->longitude_degrees) < 1.0e-5 &&
              parsed->gps->altitude_metres.has_value() &&
              std::abs(*parsed->gps->altitude_metres + 4.5) < 1.0e-5,
          "GPS Exif did not round trip");

  // HEIF metadata prefixes the TIFF payload with a four-byte TIFF offset.
  std::vector<std::uint8_t> heif_exif{0, 0, 0, 0};
  heif_exif.insert(heif_exif.end(), tiff.begin(), tiff.end());
  require(hyperdr::read_photo_metadata(heif_exif.data(), heif_exif.size())
              .has_value(),
          "HEIF-prefixed Exif was not parsed");

  // JPEG uses an APP1 marker containing Exif\0\0 followed by the TIFF block.
  const std::size_t app1_size = 2 + 6 + tiff.size();
  require(app1_size <= 65535, "test Exif exceeds one JPEG APP1 segment");
  std::vector<std::uint8_t> jpeg{0xFF, 0xD8, 0xFF, 0xE1,
                                 static_cast<std::uint8_t>(app1_size >> 8),
                                 static_cast<std::uint8_t>(app1_size)};
  jpeg.insert(jpeg.end(), {'E', 'x', 'i', 'f', 0, 0});
  jpeg.insert(jpeg.end(), tiff.begin(), tiff.end());
  jpeg.insert(jpeg.end(), {0xFF, 0xD9});
  const auto jpeg_parsed =
      hyperdr::read_jpeg_photo_metadata(jpeg.data(), jpeg.size());
  require(jpeg_parsed.has_value() && jpeg_parsed->model == source.model,
          "JPEG Exif APP1 was not parsed");
}

// The reader parses attacker-controlled bytes, so "malformed" must mean
// "nullopt", never a read past the block.
void test_orientation_reader() {
  const auto tiff = [](bool big_endian, std::uint16_t orientation,
                       std::uint16_t type = 3,
                       std::uint32_t count = 1) {
    std::vector<std::uint8_t> out;
    const auto u16 = [&](std::uint16_t v) {
      if (big_endian) { out.push_back(v >> 8); out.push_back(v & 0xFF); }
      else { out.push_back(v & 0xFF); out.push_back(v >> 8); }
    };
    const auto u32 = [&](std::uint32_t v) {
      if (big_endian) {
        out.push_back(v >> 24); out.push_back((v >> 16) & 0xFF);
        out.push_back((v >> 8) & 0xFF); out.push_back(v & 0xFF);
      } else {
        out.push_back(v & 0xFF); out.push_back((v >> 8) & 0xFF);
        out.push_back((v >> 16) & 0xFF); out.push_back(v >> 24);
      }
    };
    out.push_back(big_endian ? 'M' : 'I');
    out.push_back(big_endian ? 'M' : 'I');
    u16(42);
    u32(8);           // IFD0 offset
    u16(1);           // one entry
    u16(0x0112);      // Orientation
    u16(type);
    u32(count);
    u16(orientation);
    u16(0);           // value padding
    u32(0);           // next IFD
    return out;
  };

  for (const bool big_endian : {false, true}) {
    for (std::uint16_t orientation = 1; orientation <= 8; ++orientation) {
      const auto bytes = tiff(big_endian, orientation);
      const auto read = hyperdr::read_exif_orientation(bytes.data(), bytes.size());
      require(read.has_value() && *read == orientation,
              "orientation must round trip in both byte orders");
    }
  }

  const auto valid = tiff(false, 6);
  require(!hyperdr::read_exif_orientation(nullptr, 0).has_value(), "null block");
  require(!hyperdr::read_exif_orientation(valid.data(), 4).has_value(),
          "a block too short for a TIFF header is not an orientation");
  // Truncated one byte before the end of the entry: the bounds check has to
  // catch it rather than reading the byte after the buffer.
  require(!hyperdr::read_exif_orientation(valid.data(), 14).has_value(),
          "a truncated IFD is rejected");

  auto bad_magic = valid;
  bad_magic[0] = 'X';
  require(!hyperdr::read_exif_orientation(bad_magic.data(), bad_magic.size()).has_value(),
          "an unknown byte order marker is rejected");

  auto bad_version = valid;
  bad_version[2] = 43;
  require(!hyperdr::read_exif_orientation(bad_version.data(), bad_version.size()).has_value(),
          "a wrong TIFF version is rejected");

  const auto out_of_range = tiff(false, 9);
  require(!hyperdr::read_exif_orientation(out_of_range.data(), out_of_range.size()).has_value(),
          "an orientation outside 1..8 is rejected");

  const auto wrong_type = tiff(false, 6, /*type=*/4);
  require(!hyperdr::read_exif_orientation(wrong_type.data(), wrong_type.size()).has_value(),
          "orientation must be a SHORT");

  // A hostile entry count that would run far past the block.
  auto huge_count = valid;
  huge_count[8] = 0xFF;
  huge_count[9] = 0xFF;
  require(!hyperdr::read_exif_orientation(huge_count.data(), huge_count.size()).has_value(),
          "an entry count larger than the block is rejected");

  // A hostile IFD0 offset near the top of the address space.
  auto huge_offset = valid;
  huge_offset[4] = 0xFF; huge_offset[5] = 0xFF;
  huge_offset[6] = 0xFF; huge_offset[7] = 0xFF;
  require(!hyperdr::read_exif_orientation(huge_offset.data(), huge_offset.size()).has_value(),
          "an out-of-range IFD offset is rejected");
}

// The writer and the reader, checked against each other.
//
// Container inputs used to arrive with no camera and no capture settings at
// all, and the exported file claimed a manufacturer of "HEIC". Reading Exif
// back is what fixed that, and holding it to what make_minimal_exif emits is
// the only check that cannot drift: if either side changes its mind about a
// tag, this fails.
void test_round_trip() {
  hyperdr::PhotoMetadata written;
  written.make = "SONY";
  written.model = "ILCE-7RM5";
  written.lens = "FE 24-70mm F2.8 GM II";
  written.lens_make = "SONY";
  written.artist = "A Photographer";
  written.copyright = "All rights reserved";
  written.date_time = "2026:08:08 12:34:56";
  written.orientation = 6;
  written.iso = 12800;
  written.exposure_seconds = 1.0 / 250.0;
  written.aperture = 2.8;
  written.focal_length_mm = 35.0;
  written.focal_length_35mm = 35.0;

  const auto block = hyperdr::make_minimal_exif(written);
  const auto read = hyperdr::read_exif(block.data(), block.size());
  const auto& m = read.metadata;
  require(m.make == written.make, "Make did not survive the round trip");
  require(m.model == written.model, "Model did not survive the round trip");
  require(m.lens == written.lens, "LensModel did not survive the round trip");
  require(m.lens_make == written.lens_make, "LensMake did not survive the round trip");
  require(m.artist == written.artist, "Artist did not survive the round trip");
  require(m.copyright == written.copyright, "Copyright did not survive the round trip");
  require(m.iso == written.iso, "ISO did not survive the round trip");
  require(std::abs(m.exposure_seconds - written.exposure_seconds) < 1.0e-4,
          "ExposureTime did not survive the round trip");
  require(std::abs(m.aperture - written.aperture) < 1.0e-4,
          "FNumber did not survive the round trip");
  require(std::abs(m.focal_length_mm - written.focal_length_mm) < 1.0e-3,
          "FocalLength did not survive the round trip");
  require(m.focal_length_35mm == written.focal_length_35mm,
          "FocalLengthIn35mmFilm did not survive the round trip");
  require(read.orientation.has_value() && *read.orientation == 6,
          "Orientation did not survive the round trip");

  // An empty Make writes no tag rather than an empty one, and reads back empty.
  hyperdr::PhotoMetadata anonymous;
  anonymous.model = "Unnamed";
  const auto blank = hyperdr::make_minimal_exif(anonymous);
  const auto blank_read = hyperdr::read_exif(blank.data(), blank.size());
  require(blank_read.metadata.make.empty(), "an absent Make must read back empty");
  require(blank_read.metadata.model == "Unnamed", "Model is independent of Make");
  require(!blank_read.orientation.has_value() || *blank_read.orientation == 1,
          "a default orientation reads back as upright");
}

// A HEIF `Exif` item prefixes the TIFF header with a four-byte offset. The
// reader finds the byte-order mark instead of making every container's caller
// know its own preamble, so both shapes have to work.
void test_preamble_is_skipped() {
  hyperdr::PhotoMetadata written;
  written.model = "Prefixed";
  written.orientation = 6;
  written.iso = 400;
  const auto tiff = hyperdr::make_minimal_exif(written);

  std::vector<std::uint8_t> prefixed{0, 0, 0, 0};
  prefixed.insert(prefixed.end(), tiff.begin(), tiff.end());
  const auto read = hyperdr::read_exif(prefixed.data(), prefixed.size());
  require(read.metadata.model == "Prefixed",
          "a HEIF Exif item's offset prefix must be skipped");
  require(read.metadata.iso == 400, "capture settings survive the prefix");
  require(read.orientation && *read.orientation == 6,
          "orientation survives the HEIF Exif prefix");

  // Not Exif at all: no byte-order mark anywhere in the leading window.
  const std::vector<std::uint8_t> noise(64, 0x7F);
  require(hyperdr::read_exif(noise.data(), noise.size()).metadata.model.empty(),
          "a block with no TIFF header yields nothing");
  require(hyperdr::read_exif(nullptr, 0).metadata.model.empty(),
          "an absent block yields nothing");
}

}  // namespace

int main() {
  try {
    test_exif();
    test_portable_metadata_round_trip();
    test_orientation_reader();
    test_round_trip();
    test_preamble_is_skipped();
    std::cout << "Exif tests passed\n";
    return 0;
  } catch (const std::exception& e) {
    std::cerr << "test failure: " << e.what() << '\n';
    return 1;
  }
}
