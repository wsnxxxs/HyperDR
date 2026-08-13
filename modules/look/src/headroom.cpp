#include "hyperdr/look/analysis.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <vector>

namespace hyperdr {

namespace {

struct HighlightEvidence {
  float peak{};
  float merit{};
};

float choose_content_headroom_stops(const SceneStatistics& stats,
                                    float exposure,
                                    const CaptureMetadata& capture,
                                    float maximum_stops, float pop) {
  if (stats.samples.empty() || !(exposure > 0.0F)) return 0.0F;
  // P99.99 is always at least P99.9 under the nearest-rank definition. Keeping
  // both made the max look like two independent pieces of evidence even though
  // the P99.9 arm could never win.
  const float high = stats.p9999 * exposure;
  if (!(std::isfinite(high) && high > 1.0F)) return 0.0F;

  std::size_t bright_count = 0;
  for (const float sample : stats.samples) {
    if (sample * exposure > 1.0F) ++bright_count;
  }
  const float bright_fraction =
      static_cast<float>(bright_count) /
      static_cast<float>(stats.samples.size());
  const float absolute_merit = smoothstep(1.0F, 4.0F, high);
  const float area_merit =
      std::min(1.0F, (0.60F + 0.20F * pop) +
                        0.40F * smoothstep(0.0F, 0.02F,
                                                   bright_fraction));
  const float iso_merit =
      capture.iso && std::isfinite(*capture.iso) && *capture.iso > 0.0F
          ? 1.0F -
                0.60F * smoothstep(800.0F, 25600.0F, *capture.iso)
          : 0.90F;
  const float content_stops = std::log2(high);
  return std::clamp(
      (content_stops + 0.20F + 0.25F * pop) * absolute_merit * area_merit *
          iso_merit,
      0.0F, maximum_stops);
}

HighlightEvidence find_local_highlight_evidence(
    const std::vector<float>& cell_mean, const std::vector<float>& cell_peak,
    std::uint32_t width, std::uint32_t height, float exposure,
    const CaptureMetadata& capture) {
  const std::size_t count = static_cast<std::size_t>(width) * height;
  std::vector<std::uint8_t> candidate(count, 0);
  std::vector<float> quality(count, 0.0F);
  std::vector<float> contrast(count, 0.0F);
  const float iso_confidence =
      capture.iso && std::isfinite(*capture.iso) && *capture.iso > 0.0F
          ? 1.0F -
                0.85F * smoothstep(800.0F, 12800.0F, *capture.iso)
          : 0.70F;
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      const std::size_t index = static_cast<std::size_t>(y) * width + x;
      const float peak = cell_peak[index] * exposure;
      if (!(std::isfinite(peak) && peak > 1.0F)) continue;
      float environment_sum = 0.0F;
      unsigned environment_count = 0;
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          if (dx == 0 && dy == 0) continue;
          const int nx = static_cast<int>(x) + dx;
          const int ny = static_cast<int>(y) + dy;
          if (nx < 0 || ny < 0 || nx >= static_cast<int>(width) ||
              ny >= static_cast<int>(height))
            continue;
          environment_sum +=
              cell_mean[static_cast<std::size_t>(ny) * width + nx] * exposure;
          ++environment_count;
        }
      }
      const float environment =
          environment_count == 0
              ? cell_mean[index] * exposure
              : environment_sum / environment_count;
      const float local_contrast =
          std::log2((peak + kEpsilon) /
                    (environment + kEpsilon));
      if (!(std::isfinite(local_contrast) && local_contrast >= 0.40F))
        continue;
      const float score = smoothstep(1.0F, 4.0F, peak) *
                          smoothstep(0.40F, 2.50F, local_contrast) *
                          iso_confidence;
      if (score < 0.05F) continue;
      candidate[index] = 1;
      quality[index] = score;
      contrast[index] = local_contrast;
    }
  }

  std::vector<std::uint8_t> visited(count, 0);
  std::vector<std::size_t> queue;
  HighlightEvidence best;
  for (std::size_t start = 0; start < count; ++start) {
    if (candidate[start] == 0 || visited[start] != 0) continue;
    queue.clear();
    queue.push_back(start);
    visited[start] = 1;
    std::size_t cells = 0;
    float peak = 0.0F;
    float best_quality = 0.0F;
    float best_contrast = 0.0F;
    for (std::size_t cursor = 0; cursor < queue.size(); ++cursor) {
      const auto index = queue[cursor];
      const auto x = static_cast<std::uint32_t>(index % width);
      const auto y = static_cast<std::uint32_t>(index / width);
      ++cells;
      peak = std::max(peak, cell_peak[index] * exposure);
      best_quality = std::max(best_quality, quality[index]);
      best_contrast = std::max(best_contrast, contrast[index]);
      for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
          if (dx == 0 && dy == 0) continue;
          const int nx = static_cast<int>(x) + dx;
          const int ny = static_cast<int>(y) + dy;
          if (nx < 0 || ny < 0 || nx >= static_cast<int>(width) ||
              ny >= static_cast<int>(height))
            continue;
          const auto neighbor =
              static_cast<std::size_t>(ny) * width + nx;
          if (candidate[neighbor] != 0 && visited[neighbor] == 0) {
            visited[neighbor] = 1;
            queue.push_back(neighbor);
          }
        }
      }
    }
    // A single cell can be one defective sensor site: cell_peak deliberately
    // retains that site even when the cell mean and P99.99 reject it. Require
    // spatial support unconditionally; a genuine tiny lamp still spans
    // adjacent cells at the half-resolution gain-grid sampling used here.
    if (cells < 2 || best_quality < 0.10F) continue;
    const float area_merit =
        0.60F +
        0.40F * smoothstep(1.0F, 8.0F, static_cast<float>(cells));
    const float merit = std::clamp(best_quality * area_merit, 0.0F, 1.0F);
    if (peak > best.peak) best = {peak, merit};
  }
  return best;
}
}  // namespace

float choose_headroom_stops(
    const SceneStatistics& stats, float exposure,
    const CaptureMetadata& capture, float maximum_stops,
    const std::vector<float>& cell_mean, const std::vector<float>& cell_peak,
    std::uint32_t width, std::uint32_t height, float pop) {
  const float percentile_stops = choose_content_headroom_stops(
      stats, exposure, capture, maximum_stops, pop);
  const auto local = find_local_highlight_evidence(
      cell_mean, cell_peak, width, height, exposure, capture);
  if (!(local.peak > 1.0F && local.merit > 0.0F)) return percentile_stops;
  const float local_stops =
      (std::log2(local.peak) + 0.20F + 0.25F * pop) * local.merit;
  return std::clamp(std::max(percentile_stops, local_stops), 0.0F,
                    maximum_stops);
}

}  // namespace hyperdr
