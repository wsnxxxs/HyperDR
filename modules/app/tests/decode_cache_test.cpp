#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/codec/dcp_profile.hpp"
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
  require(source.linear_p3.pixels == cached.linear_p3.pixels,
          "cache changed decoded pixels");
  require(source.raw_lens_profile_path == cached.raw_lens_profile_path &&
              source.raw_lens_correction == cached.raw_lens_correction,
          "cache changed lens correction provenance");
}

// Standalone little-endian DCP with one identity-like ColorMatrix and D65.
void write_profile(const std::filesystem::path& path, std::uint32_t first) {
  std::vector<std::uint8_t> bytes{'I', 'I'};
  const auto put = [&](std::uint32_t value, unsigned size) {
    for (unsigned i = 0; i < size; ++i)
      bytes.push_back(static_cast<std::uint8_t>(value >> (8*i)));
  };
  put(0x4352,2); put(8,4); put(2,2);
  put(50721,2); put(10,2); put(9,4); put(38,4);
  put(50778,2); put(3,2); put(1,4); put(21,4);
  put(0,4);
  for (unsigned i = 0; i < 9; ++i) {
    put(i == 0 ? first : (i%4 == 0 ? 10000 : 0),4);
    put(10000,4);
  }
  hyperdr::write_binary_file_atomic(path,bytes,true);
}

void profile_round_trip(const std::filesystem::path& directory) {
  const auto profile_path = directory / "camera.dcp";
  const auto cache_path = directory / "profile.hdrcache";
  write_profile(profile_path,10000);
  auto profile = std::make_shared<hyperdr::DcpProfile>(hyperdr::read_dcp_profile(profile_path));
  auto context = std::make_shared<hyperdr::DcpRenderContext>();
  context->profile = profile;
  context->illuminant_weight = .375;
  context->baseline_exposure = .25F;
  hyperdr::DecodedImage source;
  source.raw_profile_path = profile_path;
  source.raw_profile = context;
  source.linear_p3 = hyperdr::FloatImage(2,2,3);
  for (std::size_t i=0; i<source.linear_p3.pixels.size(); ++i)
    source.linear_p3.pixels[i] = static_cast<float>(i) / 16;
  require(hyperdr::write_decode_cache(cache_path,source),"DCP cache write failed");
  hyperdr::DecodedImage cached;
  require(hyperdr::read_decode_cache(cache_path,cached),"DCP cache must hit");
  require(cached.raw_profile && cached.raw_profile->profile,"DCP context was not restored");
  require(cached.raw_profile_path == profile_path && cached.raw_profile->profile->sha256 == profile->sha256,
          "DCP identity changed after caching");
  require(cached.raw_profile->illuminant_weight == context->illuminant_weight &&
              cached.raw_profile->baseline_exposure == context->baseline_exposure,
          "DCP interpolation or exposure changed after caching");
  require(cached.linear_p3.pixels == source.linear_p3.pixels,"DCP cache changed pixels");
  hyperdr::ConvertOptions options;
  options.raw.profile = profile_path;
  const auto before = hyperdr::decode_cache_variant(options,options.raw);
  require(before.find(profile->sha256) != std::string::npos,"cache variant must include DCP content hash");
  // Same filename and file size; contents alone must invalidate the old entry.
  write_profile(profile_path,11000);
  require(!hyperdr::read_decode_cache(cache_path,cached),"replaced DCP must invalidate cached pixels");
  const auto after = hyperdr::decode_cache_variant(options,options.raw);
  require(after != before,"same-path DCP replacement must change decode variant");
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
    source.raw_lens_profile_path = directory / "lens.lcp";
    source.raw_lens_correction = "distortion,vignette";
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
    profile_round_trip(directory);
    std::filesystem::remove_all(directory);
    std::cout << "decode cache tests passed\n";
  } catch (const std::exception& error) {
    std::filesystem::remove_all(directory);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
