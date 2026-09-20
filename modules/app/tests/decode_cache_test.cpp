#include "hyperdr/app/decode_cache.hpp"

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
  require(source.linear_p3.pixels == cached.linear_p3.pixels,
          "cache changed decoded pixels");
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
    // Values beyond the report writer's precision must survive exactly, since
    // even small rounding can change a tree's branch. Zero EV remains present.
    source.metadata.capture = {125.0, 1.0 / 693.0, 1.7999999523162842,
                               0.0, 4.73992180818545, 36.5};
    source.capture = {125.0F, 1.0F / 693.0F, 1.8F, 0.0F,
                      4.73992180818545F, 36.5F};
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
