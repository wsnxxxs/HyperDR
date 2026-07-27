// --skip-existing used to compare modification times only, so changing the
// look and re-running silently skipped every file and shipped the previous
// render. These cases pin the fingerprint: it must change when anything that
// affects the encoded bytes changes, and must not change for options that only
// affect scheduling or reporting.

#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/app/batch.hpp"
#include "hyperdr/app/fingerprint.hpp"
#include "hyperdr/app/resume_state.hpp"

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {

void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

hyperdr::ConvertOptions base_options() {
  hyperdr::ConvertOptions options;
  options.input = "input";
  options.output_directory = "output";
  return options;
}

void check_render_options_change_the_fingerprint() {
  const auto reference = hyperdr::settings_fingerprint(base_options());
  require(reference.size() == 16, "fingerprint should be a 64-bit hex digest");

  const auto changed = [&](auto&& mutate) {
    auto options = base_options();
    mutate(options);
    return hyperdr::settings_fingerprint(options) != reference;
  };

  require(changed([](auto& o) { o.gain.look.contrast = 1.20F; }), "contrast");
  require(changed([](auto& o) { o.gain.look.vibrance = 0.30F; }), "vibrance");
  require(changed([](auto& o) { o.gain.look.pop = 0.5F; }), "pop");
  require(changed([](auto& o) { o.gain.look.headroom_max_stops = 2.0F; }), "headroom max");
  require(changed([](auto& o) { o.gain.look.shoulder_start = 0.6F; }), "expansion start");
  require(changed([](auto& o) { o.gain.look.diffuse_gain_floor = 0.7F; }), "area coverage");
  require(changed([](auto& o) { o.gain.look.mode = hyperdr::LookMode::kNeutral; }), "look");
  require(changed([](auto& o) { o.gain.gain_strength = 0.5F; }), "gain strength");
  require(changed([](auto& o) { o.gain.exposure_bias_ev = 0.0F; }), "exposure bias");
  require(changed([](auto& o) { o.gain.auto_exposure = false; }), "auto exposure");
  require(changed([](auto& o) { o.gain.auto_headroom = false; }), "auto headroom");
  require(changed([](auto& o) { o.quality = 80; }), "quality");
  require(changed([](auto& o) { o.depth = 10; }), "depth");
  require(changed([](auto& o) { o.encoding = hyperdr::HdrEncoding::UltraHdr; }), "encoding");
  require(changed([](auto& o) { o.preview_max_edge = 1600; }), "preview bound");
  require(changed([](auto& o) {
            o.raw.highlight_recovery = hyperdr::HighlightRecovery::Reconstruct;
          }),
          "highlight recovery");
}

void check_scheduling_options_do_not_change_it() {
  const auto reference = hyperdr::settings_fingerprint(base_options());
  const auto unchanged = [&](auto&& mutate) {
    auto options = base_options();
    mutate(options);
    return hyperdr::settings_fingerprint(options) == reference;
  };
  require(unchanged([](auto& o) { o.verify_output = false; }), "verification");
  require(unchanged([](auto& o) { o.overwrite = true; }), "overwrite");
  require(unchanged([](auto& o) { o.skip_existing = true; }), "skip existing");
  require(unchanged([](auto& o) { o.recursive = true; }), "recursive");
  require(unchanged([](auto& o) { o.report_path = "report.json"; }), "report path");
}

void check_resume_rejects_damaged_output() {
  const auto root = std::filesystem::temp_directory_path() / "hyperdr-resume-integrity-test";
  std::filesystem::remove_all(root);
  std::filesystem::create_directories(root / "output");
  const auto input = root / "input.jpg";
  const auto output = root / "output" / "result.heic";
  { std::ofstream file(input, std::ios::binary); file << "input"; }
  { std::ofstream file(output, std::ios::binary); file << "result-one"; }
  auto options = base_options();
  options.output_directory = root / "output";
  const std::string fingerprint = "fingerprint";
  hyperdr::write_resume_state(
      output, input, hyperdr::input_stamp(input), options, fingerprint);
  require(hyperdr::output_is_current(output, input, options, fingerprint),
          "fresh output did not match its resume state");
  { std::ofstream file(output, std::ios::binary | std::ios::trunc); file << "result-two"; }
  require(!hyperdr::output_is_current(output, input, options, fingerprint),
          "same-size replaced output matched stale resume state");
  { std::ofstream file(output, std::ios::binary | std::ios::trunc); file << "x"; }
  require(!hyperdr::output_is_current(output, input, options, fingerprint),
          "truncated output matched stale resume state");
  std::filesystem::remove_all(root);
}

void check_decode_cache_roundtrip() {
  const auto directory = std::filesystem::temp_directory_path() / "hyperdr-cache-test";
  std::filesystem::remove_all(directory);
  std::filesystem::create_directories(directory);

  hyperdr::DecodedImage value;
  value.linear_p3 = hyperdr::FloatImage(7, 5, 3);
  for (std::uint32_t y = 0; y < 5; ++y) {
    for (std::uint32_t x = 0; x < 7; ++x) {
      for (std::uint32_t c = 0; c < 3; ++c) {
        value.linear_p3.at(x, y, c) = static_cast<float>(x * 100 + y * 10 + c) / 7.0F;
      }
    }
  }
  value.metadata.make = "SONY";
  value.metadata.model = "ILCE-7RM5";
  value.metadata.lens = "FE 35mm F1.4 GM";
  value.metadata.iso = 640;
  value.metadata.orientation = 1;
  value.capture.iso = 640.0F;
  value.capture.exposure_time_seconds = 1.0F / 250.0F;
  value.capture.aperture_f_number = 1.8F;
  value.decode.sensor_width = 9600;
  value.decode.sensor_height = 6400;
  value.decode.target_width = 9504;
  value.decode.target_height = 6336;
  value.decode.decoded_width = 4752;
  value.decode.decoded_height = 3168;
  value.decode.resolution_reduced = true;
  value.decode.default_crop_present = true;
  value.decode.target_dimensions_applied = true;
  value.decode.degraded = true;
  value.decode.degradation_reasons = {"default_crop_rejected"};

  const auto file = hyperdr::decode_cache_path(directory, "roundtrip");
  require(hyperdr::write_decode_cache(file, value), "cache write should succeed");

  hyperdr::DecodedImage loaded;
  require(hyperdr::read_decode_cache(file, loaded), "cache read should succeed");
  require(loaded.linear_p3.width == 7 && loaded.linear_p3.height == 5, "dimensions");
  require(loaded.linear_p3.pixels == value.linear_p3.pixels, "pixels must round-trip exactly");
  require(loaded.metadata.model == "ILCE-7RM5", "metadata must round-trip");
  require(loaded.metadata.lens == "FE 35mm F1.4 GM", "lens must round-trip");
  require(loaded.capture.aperture_f_number.has_value(), "optional capture value");
  require(loaded.decode.target_width == 9504, "decode target must round-trip");
  require(loaded.decode.decoded_width == 4752, "decode output must round-trip");
  require(loaded.decode.resolution_reduced,
          "resolution reduction must round-trip");
  require(loaded.decode.degraded, "decode degradation must round-trip");
  require(loaded.decode.target_dimensions_applied,
          "the target-applied predicate must round-trip");
  require(loaded.decode.default_crop_present,
          "DefaultCrop presence must round-trip");
  require(loaded.decode.degradation_reasons.size() == 1 &&
              loaded.decode.degradation_reasons.front() ==
                  "default_crop_rejected",
          "decode degradation reasons must round-trip");

  // A truncated file is a miss, never a crash or a half-filled image.
  {
    std::ofstream truncate(file, std::ios::binary | std::ios::trunc);
    truncate.write("HDRCACH2", 8);
  }
  hyperdr::DecodedImage broken;
  require(!hyperdr::read_decode_cache(file, broken), "a truncated cache must be a miss");
  require(!hyperdr::read_decode_cache(directory / "absent.hdrcache", broken),
          "an absent cache must be a miss");

  std::filesystem::remove_all(directory);
}

void check_decode_cache_key_varies() {
  const auto self = std::filesystem::temp_directory_path() / "hyperdr-key-test.bin";
  {
    std::ofstream output(self, std::ios::binary);
    output << "fixture";
  }
  const auto blend_full = hyperdr::decode_cache_key(self, "blend/full/0");
  require(blend_full != hyperdr::decode_cache_key(self, "clip/full/0"),
          "highlight recovery must change the cache key");
  require(blend_full != hyperdr::decode_cache_key(self, "blend/half/0"),
          "half-size decode must change the cache key");
  require(blend_full != hyperdr::decode_cache_key(self, "blend/full/1600"),
          "the preview bound must change the cache key");
  require(blend_full == hyperdr::decode_cache_key(self, "blend/full/0"),
          "the key must be stable for identical inputs");
  std::filesystem::remove(self);
}

void check_export_rejects_reduced_resolution() {
  auto export_options = base_options();
  hyperdr::DecodeInfo reduced;
  reduced.resolution_reduced = true;
  bool rejected = false;
  try {
    hyperdr::require_decode_resolution(export_options, reduced);
  } catch (const std::runtime_error&) {
    rejected = true;
  }
  require(rejected, "strict export accepted a reduced-resolution decode");

  export_options.decode_intent = hyperdr::DecodeIntent::Preview;
  hyperdr::require_decode_resolution(export_options, reduced);

  hyperdr::DecodeInfo full;
  hyperdr::require_decode_resolution(base_options(), full);
}

void check_prune_respects_the_budget() {
  const auto directory = std::filesystem::temp_directory_path() / "hyperdr-prune-test";
  std::filesystem::remove_all(directory);
  std::filesystem::create_directories(directory);
  for (int i = 0; i < 8; ++i) {
    std::ofstream output(hyperdr::decode_cache_path(directory, "entry" + std::to_string(i)),
                         std::ios::binary);
    output << std::string(1024, 'x');
  }
  hyperdr::prune_decode_cache(directory, 4 * 1024);
  std::uint64_t total = 0;
  for (const auto& item : std::filesystem::directory_iterator(directory)) {
    total += static_cast<std::uint64_t>(std::filesystem::file_size(item.path()));
  }
  require(total <= 4 * 1024, "prune must bring the directory under its budget");
  std::filesystem::remove_all(directory);
}

}  // namespace

int main() {
  try {
    check_render_options_change_the_fingerprint();
    check_scheduling_options_do_not_change_it();
    check_resume_rejects_damaged_output();
    check_decode_cache_roundtrip();
    check_decode_cache_key_varies();
    check_export_rejects_reduced_resolution();
    check_prune_respects_the_budget();
  } catch (const std::exception& e) {
    std::cerr << "resume_state_test failed: " << e.what() << '\n';
    return 1;
  }
  std::cout << "resume_state_test passed\n";
  return 0;
}
