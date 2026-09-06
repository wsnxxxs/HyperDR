#include "hyperdr/app/analysis_cache.hpp"
#include "hyperdr/app/decode_cache.hpp"

#include <chrono>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}
}

int main() {
  const auto directory = std::filesystem::temp_directory_path() /
      ("hyperdr-analysis-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
  try {
    std::filesystem::create_directories(directory);
    const auto source_path = directory / "input.raw";
    std::ofstream(source_path) << "fixture";
    hyperdr::FloatImage source(128, 160, 3);
    for (std::size_t i = 0; i < source.pixels.size(); ++i)
      source.pixels[i] = 0.01F + static_cast<float>(i % 997) * 0.007F;
    const auto path = directory / "fixture.analysis.hdrcache";
    bool hit = true;
    const auto first = hyperdr::cached_photographic_analysis(source, path, 0, &hit);
    require(!hit, "first analysis must be a miss");
    const auto again = hyperdr::cached_photographic_analysis(source, path, 0, &hit);
    require(hit && first.cell_mean == again.cell_mean && first.cell_peak == again.cell_peak &&
                first.scene_stats.samples == again.scene_stats.samples,
            "warm analysis cache did not retain source measurements");
    hyperdr::GainMapOptions options;
    options.look.shoulder_start = 0.32F;
    options.exposure_bias_ev = 0.7F;
    options.gain_strength = 0.6F;
    const auto reference = hyperdr::make_gain_map(source, options);
    const auto cached = hyperdr::make_gain_map(source, options, {}, {}, &again);
    require(reference.base_linear.pixels == cached.base_linear.pixels &&
                reference.gain_map.pixels == cached.gain_map.pixels &&
                reference.exposure_ev == cached.exposure_ev &&
                reference.headroom_stops == cached.headroom_stops,
            "reusing source analysis changed the adjusted image");
    std::ofstream(path, std::ios::binary | std::ios::trunc) << "truncated";
    const auto repaired = hyperdr::cached_photographic_analysis(source, path, 0, &hit);
    require(!hit && repaired.cell_mean == first.cell_mean, "truncated analysis did not rebuild");
    {
      std::fstream corrupt(path, std::ios::binary | std::ios::in | std::ios::out);
      corrupt.seekp(-static_cast<std::streamoff>(sizeof(float)), std::ios::end);
      const float invalid = std::numeric_limits<float>::quiet_NaN();
      corrupt.write(reinterpret_cast<const char*>(&invalid), sizeof(invalid));
    }
    const auto finite = hyperdr::cached_photographic_analysis(source, path, 0, &hit);
    require(!hit && finite.cell_peak == first.cell_peak, "nonfinite cache cell did not rebuild");
    hyperdr::ConvertOptions before, after;
    const auto base_variant = hyperdr::decode_cache_variant(before, before.raw);
    after.gain = options;
    require(base_variant == hyperdr::decode_cache_variant(after, after.raw),
            "look changes invalidated source analysis identity");
    after.preview_max_edge = 640;
    require(base_variant != hyperdr::decode_cache_variant(after, after.raw),
            "preview geometry did not invalidate analysis identity");
    after = before;
    after.raw.half_size = true;
    require(base_variant != hyperdr::decode_cache_variant(after, after.raw),
            "RAW decoding change did not invalidate analysis identity");
    const auto key = hyperdr::decode_cache_key(source_path, base_variant);
    std::ofstream(source_path) << "different source";
    require(key != hyperdr::decode_cache_key(source_path, base_variant),
            "source replacement did not invalidate analysis identity");
    hyperdr::prune_decode_cache(directory, 1);
    require(!std::filesystem::exists(path), "analysis cache escaped the shared budget");
    std::filesystem::remove_all(directory);
    std::cout << "analysis cache tests passed\n";
  } catch (const std::exception& error) {
    std::filesystem::remove_all(directory);
    std::cerr << error.what() << '\n';
    return 1;
  }
}
