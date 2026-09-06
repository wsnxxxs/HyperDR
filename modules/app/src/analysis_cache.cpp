#include "hyperdr/app/analysis_cache.hpp"

#include "hyperdr/app/decode_cache.hpp"
#include "hyperdr/foundation/binary_input.hpp"
#include "hyperdr/foundation/file_io.hpp"
#include "hyperdr/foundation/parallel.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace hyperdr {
namespace {

// Local little-endian cache, like the decoded float buffers beside it.
constexpr std::uint32_t kMagic = 0x414e5244U;
constexpr std::uint32_t kVersion = 2;

bool read_analysis(const FloatImage& source, const std::filesystem::path& file,
                   PhotographicAnalysis& out) {
  BinaryInput stream(file);
  if (!stream) return false;
  const auto read = [&](auto& values) {
    const auto bytes = values.size() * sizeof(values[0]);
    return stream.read(values.data(), bytes);
  };
  std::array<std::uint32_t, 7> header{};
  if (!read(header)) return false;
  const auto dimensions = choose_gain_dimensions(source);
  if (header[0] != kMagic || header[1] != kVersion ||
      header[2] != source.width || header[3] != source.height ||
      header[4] != dimensions.width || header[5] != dimensions.height) return false;
  const auto cells = static_cast<std::size_t>(dimensions.width) * dimensions.height;
  const auto pixels = static_cast<std::size_t>(source.width) * source.height;
  const auto max_samples = std::min<std::size_t>(pixels, 512U * 512U);
  if (header[6] > max_samples) return false;
  std::error_code ec;
  const auto bytes = std::filesystem::file_size(file, ec);
  if (ec || bytes != sizeof(header) + (3ULL + header[6] + 2ULL * cells) * sizeof(float))
    return false;
  std::array<float, 3> stats{};
  if (!read(stats)) return false;
  out.dimensions = dimensions;
  out.scene_stats.samples.resize(header[6]);
  out.cell_mean.resize(cells);
  out.cell_peak.resize(cells);
  for (auto* values : {&out.scene_stats.samples, &out.cell_mean, &out.cell_peak}) {
    if (!read(*values)) return false;
  }
  const auto valid = [](float v) { return std::isfinite(v) && v >= 0; };
  if (!std::all_of(stats.begin(), stats.end(), valid) ||
      !std::all_of(out.scene_stats.samples.begin(), out.scene_stats.samples.end(), valid))
    return false;
  // Cell arrays grow with export resolution. Validate independent rows with
  // the same pool as source analysis so a cache hit does not serialize them.
  std::vector<std::uint8_t> valid_rows(dimensions.height, 1);
  parallel_for_rows(dimensions.height, [&](std::uint32_t y) {
    const auto begin = static_cast<std::size_t>(y) * dimensions.width;
    for (auto i = begin; i < begin + dimensions.width; ++i) {
      if (!valid(out.cell_mean[i]) || !valid(out.cell_peak[i])) {
        valid_rows[y] = 0;
        break;
      }
    }
  });
  if (std::find(valid_rows.begin(), valid_rows.end(), 0) != valid_rows.end()) return false;
  out.scene_stats.log_average = stats[0];
  out.scene_stats.p995 = stats[1];
  out.scene_stats.p9999 = stats[2];
  std::filesystem::last_write_time(file, std::filesystem::file_time_type::clock::now(), ec);
  return true;
}

void write_analysis(const FloatImage& source, const PhotographicAnalysis& analysis,
                     const std::filesystem::path& file, std::uint64_t budget) {
  const std::array<std::uint32_t, 7> header{kMagic, kVersion, source.width, source.height,
      analysis.dimensions.width, analysis.dimensions.height,
      static_cast<std::uint32_t>(analysis.scene_stats.samples.size())};
  const std::array<float, 3> stats{analysis.scene_stats.log_average,
                                 analysis.scene_stats.p995, analysis.scene_stats.p9999};
  std::vector<std::uint8_t> bytes;
  const auto append = [&](const auto& values) {
    const auto* begin = reinterpret_cast<const std::uint8_t*>(values.data());
    if (!values.empty()) bytes.insert(bytes.end(), begin, begin + values.size() * sizeof(values[0]));
  };
  bytes.reserve(sizeof(header) + sizeof(stats) + sizeof(float) *
      (analysis.scene_stats.samples.size() + analysis.cell_mean.size() + analysis.cell_peak.size()));
  append(header); append(stats); append(analysis.scene_stats.samples);
  append(analysis.cell_mean); append(analysis.cell_peak);
  std::filesystem::create_directories(file.parent_path());
  write_binary_file_atomic(file, bytes, true);
  if (budget) prune_decode_cache(file.parent_path(), budget);
}

}  // namespace

PhotographicAnalysis cached_photographic_analysis(
    const FloatImage& source, const std::filesystem::path& file,
    std::uint64_t budget_bytes, bool* cache_hit) {
  if (cache_hit) *cache_hit = false;
  if (!file.empty()) {
    PhotographicAnalysis cached;
    if (read_analysis(source, file, cached)) {
      if (cache_hit) *cache_hit = true;
      return cached;
    }
  }
  auto analysis = analyze_photographic_source(source);
  if (!file.empty()) {
    try { write_analysis(source, analysis, file, budget_bytes); }
    catch (const std::exception&) { /* Cache storage is optional. */ }
  }
  return analysis;
}

}  // namespace hyperdr
