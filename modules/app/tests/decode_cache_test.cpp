#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/foundation/file_io.hpp"

#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

void require_same_capture(const hyperdr::CaptureParameters& before,
                          const hyperdr::CaptureParameters& after) {
  require(before.iso == after.iso &&
              before.exposure_seconds == after.exposure_seconds &&
              before.f_number == after.f_number &&
              before.exposure_bias_ev == after.exposure_bias_ev &&
              before.focal_length_mm == after.focal_length_mm &&
              before.focal_length_35mm == after.focal_length_35mm,
          "cache changed capture presence or exact inference values");
}

void round_trip(const std::filesystem::path& path,
                 const hyperdr::DecodedImage& source) {
  require(hyperdr::write_decode_cache(path, source), "cache write failed");
  hyperdr::DecodedImage cached;
  require(hyperdr::read_decode_cache(path, cached), "cache must hit after writing");
  hyperdr::ConvertOptions options;
  options.ai_model_path = "research-exif-v1";
  const auto miss = hyperdr::native_model_request(options, source.metadata);
  const auto hit = hyperdr::native_model_request(options, cached.metadata);
  require(miss.model_id == hit.model_id, "cache changed requested model");
  require_same_capture(miss.capture, hit.capture);
  require_same_capture(hyperdr::capture_parameters_from_metadata(source.capture),
                       hyperdr::capture_parameters_from_metadata(cached.capture));
  require(hyperdr::capture_parameters_complete(miss.capture) ==
              hyperdr::capture_parameters_complete(hit.capture),
          "cache changed the EXIF fallback decision");
  require(source.decode.source_width == cached.decode.source_width &&
              source.decode.source_height == cached.decode.source_height,
          "cache lost the upright full-resolution source dimensions");
  require(source.linear_p3.pixels == cached.linear_p3.pixels,
          "cache changed decoded pixels");
  require(source.source_color.name == cached.source_color.name &&
              source.source_color.primaries == cached.source_color.primaries &&
              source.source_color.transfer == cached.source_color.transfer &&
              source.source_color.source == cached.source_color.source,
          "cache lost the input colour interpretation");
  require(source.authored_sdr.has_value() == cached.authored_sdr.has_value(),
          "cache lost the authored SDR rendition");
  if (source.authored_sdr) {
    require(source.authored_sdr->pixels == cached.authored_sdr->pixels,
            "cache changed authored SDR pixels");
    require(cached.describe_input().domain == hyperdr::InputDomain::kDualRendition &&
                cached.describe_input().authored_sdr == &*cached.authored_sdr,
            "cache lost the dual rendition input contract");
    require(source.gain_map.base_offset == cached.gain_map.base_offset &&
                source.gain_map.alternate_offset == cached.gain_map.alternate_offset &&
                source.gain_map.base_headroom == cached.gain_map.base_headroom &&
                source.gain_map.alternate_headroom == cached.gain_map.alternate_headroom &&
                source.gain_map.channels == cached.gain_map.channels,
            "cache changed authored gain reconstruction metadata");
  }
}

}  // namespace

int main() {
  const auto directory = std::filesystem::temp_directory_path() /
      ("hyperdr-decode-" + std::to_string(
          std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    const auto path = directory / "capture.hdrcache";
    hyperdr::DecodedImage source;
    source.linear_p3 = hyperdr::FloatImage(16, 16, 3);
    source.decode.source_width = 6000;
    source.decode.source_height = 4000;
    source.source_color = {"Display P3", "Display P3", "sRGB", "icc"};
    // Values beyond the report writer's precision must survive exactly, since
    // even small rounding can change a tree's branch. Zero EV remains present.
    source.metadata.capture = {125.0, 1.0 / 693.0, 1.7999999523162842,
                               0.0, 4.73992180818545, 36.5};
    source.capture = {125.0F, 1.0F / 693.0F, 1.8F, 0.0F,
                      4.73992180818545F, 36.5F};
    round_trip(path, source);

    source.domain = hyperdr::InputDomain::kDualRendition;
    source.hdr_headroom = 4.0F;
    source.authored_sdr.emplace(16, 16, 3);
    for (std::size_t i = 0; i < source.linear_p3.pixels.size(); ++i) {
      source.authored_sdr->pixels[i] = static_cast<float>(i) / 1000.0F;
      source.linear_p3.pixels[i] = source.authored_sdr->pixels[i] * 4.0F;
    }
    source.gain_map.base_offset = {0.012345678F, 0.0012345678F, 0.023456789F};
    source.gain_map.alternate_offset = {0.023456789F, 0.012345678F, 0.0012345678F};
    source.gain_map.base_headroom = 1.23456789F;
    source.gain_map.alternate_headroom = 4.123456789F;
    source.gain_map.channels = 3;
    round_trip(path, source);

    source.metadata.capture.exposure_bias_ev = -2.0 / 3.0;
    source.capture.exposure_bias_ev = -2.0F / 3.0F;
    round_trip(path, source);

    // Legacy provenance values must not fabricate presence after a cache hit.
    source.metadata.iso = 125;
    source.metadata.exposure_seconds = 0.01;
    source.metadata.aperture = 1.8;
    source.metadata.focal_length_mm = 35;
    source.metadata.focal_length_35mm = 35;
    source.metadata.capture = {};
    source.capture = {};
    round_trip(path, source);

    // Schema 8 lacks the capture fields and must be a miss, not a fallback.
    {
      std::fstream old(path, std::ios::binary | std::ios::in | std::ios::out);
      old.seekp(8);
      const char schema8[4]{8, 0, 0, 0};
      old.write(schema8, sizeof(schema8));
      require(static_cast<bool>(old), "could not construct schema-8 cache");
    }
    hyperdr::DecodedImage cached;
    require(!hyperdr::read_decode_cache(path, cached), "schema-8 cache must miss");
    std::filesystem::remove_all(directory);
    std::cout << "decode cache tests passed\n";
  } catch (const std::exception& error) {
    std::filesystem::remove_all(directory);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
