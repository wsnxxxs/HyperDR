#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/image/image.hpp"

namespace hyperdr::codec {

// Preserve the camera-channel mean and shrink chroma to the energy remaining
// after clipping. This is the real-valued form of dcraw's orthogonal highlight
// blend, without integer transform truncation or division by zero for neutrals.
// Inputs are nonnegative camera samples; channels is three or four.
inline void blend_highlight_chroma(std::array<float, 4>& camera,
                                   unsigned channels, float clip) {
  if (*std::max_element(camera.begin(), camera.begin() + channels) <= clip) return;
  double mean = 0, clipped_mean = 0;
  for (unsigned c = 0; c < channels; ++c) {
    mean += camera[c];
    clipped_mean += std::min(camera[c], clip);
  }
  mean /= channels;
  clipped_mean /= channels;
  double energy = 0, clipped_energy = 0;
  for (unsigned c = 0; c < channels; ++c) {
    const double d = camera[c] - mean;
    const double clipped_d = std::min(camera[c], clip) - clipped_mean;
    energy += d * d;
    clipped_energy += clipped_d * clipped_d;
  }
  if (energy == 0) return;
  const double ratio = std::sqrt(std::min(1.0, clipped_energy / energy));
  // Clipping is non-expansive: ratio is at most one, so this convex combination
  // cannot produce values outside the original channel range.
  for (unsigned c = 0; c < channels; ++c)
    camera[c] = static_cast<float>(mean + ratio * (camera[c] - mean));
}

// Reconstruct in calibrated camera space: valid near-highlight blocks estimate
// channel/reference ratios, which propagate into clipped blocks. Keep dcraw's
// mode-3 neutral prior and reach, but use local floating-point clip references
// and include partial edge blocks. No inverse shading or extra gain is applied
// to the colour ratios. Float storage preserves estimates above sensor white.
template <typename ClipReferenceAt>
void reconstruct_highlight_channels(FloatImage& camera, unsigned block_size,
                                    const std::array<float, 4>& base_clip,
                                    ClipReferenceAt&& clip_at) {
  const auto width = camera.width, height = camera.height, channels = camera.channels;
  const unsigned reference = static_cast<unsigned>(
      std::max_element(base_clip.begin(), base_clip.begin() + channels) - base_clip.begin());
  if (!(base_clip[reference] > 0)) return;
  const unsigned columns = (width + block_size - 1) / block_size;
  const unsigned rows = (height + block_size - 1) / block_size;
  std::vector<float> ratios(static_cast<std::size_t>(columns) * rows);
  constexpr float low_fraction = 32000.0F / 65535.0F;
  constexpr float high_fraction = 64000.0F / 65535.0F;
  for (unsigned c = 0; c < channels; ++c) {
    if (c == reference) continue;
    std::fill(ratios.begin(), ratios.end(), 0.0F);
    parallel_for_rows(rows, [&](unsigned by) {
      for (unsigned bx = 0; bx < columns; ++bx) {
        const unsigned end_x = std::min(width, (bx + 1) * block_size);
        const unsigned end_y = std::min(height, (by + 1) * block_size);
        unsigned valid = 0;
        double signal = 0, reference_signal = 0;
        for (unsigned y = by * block_size; y < end_y; ++y)
          for (unsigned x = bx * block_size; x < end_x; ++x) {
            const auto clip = clip_at(x, y);
            const auto* p = camera.pixels.data() + (static_cast<std::size_t>(y) * width + x) * channels;
            const float reference_floor = 24000.0F * (clip[reference] / base_clip[reference]);
            if (clip[c] > 0 && p[c] >= low_fraction * clip[c] &&
                p[c] < high_fraction * clip[c] && p[reference] > reference_floor) {
              ++valid;
              signal += p[c];
              reference_signal += p[reference];
            }
          }
        const unsigned count = (end_x - bx * block_size) * (end_y - by * block_size);
        if (valid == count && reference_signal > 0)
          ratios[static_cast<std::size_t>(by) * columns + bx] =
              static_cast<float>(signal / reference_signal);
      }
    });
    // Negative entries stage one wave's results. Read only positive neighbours
    // until the wave is complete, so scan direction cannot affect propagation.
    // This loop is deliberately sequential: parallel staging in the same array
    // would race with neighbouring reads even if negative values are ignored.
    for (unsigned wave = 0; wave < 16; ++wave) {
      bool changed = false;
      for (unsigned y = 0; y < rows; ++y)
        for (unsigned x = 0; x < columns; ++x) {
          auto& ratio = ratios[static_cast<std::size_t>(y) * columns + x];
          if (ratio != 0) continue;
          double sum = 0;
          unsigned weight = 0;
          for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
              if (dx == 0 && dy == 0) continue;
              const int nx = static_cast<int>(x) + dx, ny = static_cast<int>(y) + dy;
              if (nx < 0 || ny < 0 || nx >= static_cast<int>(columns) || ny >= static_cast<int>(rows)) continue;
              const float neighbour = ratios[static_cast<std::size_t>(ny) * columns + nx];
              if (neighbour <= 0) continue;
              const unsigned w = dx == 0 || dy == 0 ? 2 : 1;
              sum += neighbour * w;
              weight += w;
            }
          if (weight > 3) {
            ratio = -static_cast<float>((sum + 2.0) / (weight + 2.0));
            changed = true;
          }
        }
      if (!changed) break;
      for (auto& ratio : ratios) if (ratio < 0) ratio = -ratio;
    }
    parallel_for_rows(height, [&](unsigned y) {
      for (unsigned x = 0; x < width; ++x) {
        auto* p = camera.pixels.data() + (static_cast<std::size_t>(y) * width + x) * channels;
        const auto clip = clip_at(x, y);
        if (!(clip[c] > 0) || p[c] < high_fraction * clip[c]) continue;
        float ratio = ratios[static_cast<std::size_t>(y / block_size) * columns + x / block_size];
        if (ratio == 0) ratio = 1;  // No nearby colour evidence: retain the neutral prior.
        const float recovered = p[reference] * ratio;
        if (recovered > p[c]) p[c] = recovered;
      }
    });
  }
}

}  // namespace hyperdr::codec
