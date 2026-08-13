#include "hyperdr/gainmap/render.hpp"

#include "hyperdr/foundation/math.hpp"
#include "hyperdr/foundation/parallel.hpp"
#include "hyperdr/gainmap/coding.hpp"
#include "hyperdr/image/color.hpp"
#include "hyperdr/look/grid.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

namespace hyperdr {

std::array<float, 3> render_common_chroma(float r, float g, float b,
                                           float source_y, float sdr_y,
                                           float hdr_y, float peak,
                                           const LookOptions& look) {
  if (!(source_y > kEpsilon && sdr_y > 0.0F))
    return {0.0F, 0.0F, 0.0F};
  std::array<float, 3> chroma{r - source_y, g - source_y, b - source_y};
  const float saturation =
      std::max({std::abs(chroma[0]), std::abs(chroma[1]),
                std::abs(chroma[2])}) /
      std::max(source_y, kEpsilon);
  const float vibrance_amount =
      look.vibrance * (1.0F - smoothstep(0.15F, 1.00F, saturation));
  for (float& value : chroma) value *= 1.0F + vibrance_amount;

  const float white_start = std::max(0.72F, peak * 0.70F);
  const float white_cap =
      std::lerp(0.45F, 0.28F, std::clamp(look.pop, 0.0F, 1.0F));
  const float white_amount =
      smoothstep(white_start, peak, hdr_y) * white_cap;
  for (float& value : chroma) value *= 1.0F - white_amount;

  const float sdr_ratio = sdr_y / source_y;
  const float hdr_ratio = hdr_y / source_y;
  float alpha_limit = 1.0F;
  for (const float value : chroma) {
    if (value < 0.0F) {
      alpha_limit = std::min(alpha_limit, -source_y / value);
    } else if (value > 0.0F) {
      if (sdr_ratio > kEpsilon) {
        alpha_limit =
            std::min(alpha_limit, (1.0F / sdr_ratio - source_y) / value);
      }
      if (hdr_ratio > kEpsilon) {
        alpha_limit =
            std::min(alpha_limit, (peak / hdr_ratio - source_y) / value);
      }
    }
  }
  alpha_limit = std::clamp(alpha_limit, 0.0F, 1.0F);
  // `alpha_limit` is the largest common-chroma fraction that keeps both the
  // SDR and HDR renditions inside their channel bounds.  The old tanh softener
  // was discontinuous at exactly one: values just below one were multiplied
  // by tanh(1) (~0.76), while one and above were left untouched.  A smooth sky
  // crossing that boundary therefore produced a visible contour.  The limit
  // itself is already a hue-preserving gamut compression, and using it
  // directly keeps the mapping continuous while never allowing a channel to
  // exceed the bound it was computed for.
  const float alpha = alpha_limit;
  std::array<float, 3> common{source_y + alpha * chroma[0],
                               source_y + alpha * chroma[1],
                               source_y + alpha * chroma[2]};
  const float common_y = p3_luminance(common[0], common[1], common[2]);
  if (!(common_y > kEpsilon && std::isfinite(common_y)))
    return {0.0F, 0.0F, 0.0F};
  const float scale = sdr_y / common_y;
  return {std::clamp(common[0] * scale, 0.0F, 1.0F),
          std::clamp(common[1] * scale, 0.0F, 1.0F),
          std::clamp(common[2] * scale, 0.0F, 1.0F)};
}

void render_full_resolution(const FloatImage& source, float exposure,
                            const std::vector<float>& local_grid,
                            std::uint32_t gain_width,
                            std::uint32_t gain_height,
                            float stored_gain_max, float stored_gamma,
                            float target_peak, const LookOptions& look,
                            GainMapResult& result) {
  const ToneCurveParameters curve = build_tone_curve(look);
  const float pop = std::clamp(look.pop, 0.0F, 1.0F);
  const float clarity_amount = std::lerp(0.08F, 0.14F, pop);

  result.base_linear = FloatImage(source.width, source.height, 3);

  // Bind each grid to its dimensions once, outside the per-pixel loop: the
  // view's constructor is where the buffer-length precondition is checked.
  const GridView local_view(local_grid, gain_width, gain_height);
  const GridView gain_view(result.gain_map.pixels, gain_width, gain_height);

  std::vector<float> row_peak(source.height, 1.0F);
  std::vector<float> row_below(source.height, 0.0F);
  std::vector<std::uint64_t> row_wide(source.height, 0);
  std::vector<std::uint64_t> row_lit(source.height, 0);

  parallel_for_rows(source.height, [&](const std::uint32_t y) {
    float peak = 1.0F;
    float below = 0.0F;
    std::uint64_t wide = 0;
    std::uint64_t lit = 0;
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const std::size_t base =
          (static_cast<std::size_t>(y) * source.width + x) * 3;
      const float r = positive_finite(source.pixels[base]) * exposure;
      const float g =
          positive_finite(source.pixels[base + 1]) * exposure;
      const float b =
          positive_finite(source.pixels[base + 2]) * exposure;
      const float scene = p3_luminance(r, g, b);
      const float sdr_curve = render_tone_curve(scene, 1.0F, curve);
      const float local_average = sample_grid_bilinear(
          local_view, source.width, source.height, x, y);
      const float detail_ev = std::clamp(
          std::log2((sdr_curve + kEpsilon) /
                    (local_average + kEpsilon)),
          -1.5F, 1.5F);
      const float clarity_mask =
          smoothstep(0.025F, 0.16F, sdr_curve) *
          (1.0F - 0.65F * smoothstep(0.78F, 1.0F, sdr_curve));
      const float sdr = std::clamp(
          sdr_curve *
              std::exp2(detail_ev * clarity_amount * clarity_mask),
          0.0F, 1.0F);
      const float gain_code =
          sample_grid_bilinear(gain_view, source.width, source.height, x, y);
      const float local_gain =
          stored_gain_max * decode_gain_code(gain_code, stored_gamma);
      const float hdr = sdr * std::exp2(local_gain);
      const auto base_rgb =
          render_common_chroma(r, g, b, scene, sdr, hdr, target_peak, look);
      result.base_linear.pixels[base] = base_rgb[0];
      result.base_linear.pixels[base + 1] = base_rgb[1];
      result.base_linear.pixels[base + 2] = base_rgb[2];
      peak = std::max(peak, hdr);
      if (scene <= curve.shoulder_input) {
        const float relative =
            std::abs(hdr - sdr) / std::max(sdr, kEpsilon);
        below = std::max(below, relative);
      }
      if (sdr > 0.02F) {
        ++lit;
        if (is_outside_rec709(base_rgb[0], base_rgb[1], base_rgb[2])) ++wide;
      }
    }
    row_peak[y] = peak;
    row_below[y] = below;
    row_wide[y] = wide;
    row_lit[y] = lit;
  });

  float rendered_peak = 1.0F;
  float below_knee_difference_max = 0.0F;
  std::uint64_t wide_count = 0;
  std::uint64_t lit_count = 0;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    rendered_peak = std::max(rendered_peak, row_peak[y]);
    below_knee_difference_max =
        std::max(below_knee_difference_max, row_below[y]);
    wide_count += row_wide[y];
    lit_count += row_lit[y];
  }
  const float wide_gamut_fraction =
      lit_count == 0 ? 0.0F
                     : static_cast<float>(static_cast<double>(wide_count) /
                                          static_cast<double>(lit_count));

  auto& stats = result.stats;
  stats.rendered_peak = rendered_peak;
  stats.headroom_utilization =
      target_peak > 1.0F
          ? std::clamp((rendered_peak - 1.0F) / (target_peak - 1.0F), 0.0F,
                       1.0F)
          : 0.0F;
  stats.below_knee_relative_difference_max = below_knee_difference_max;
  stats.wide_gamut_fraction = wide_gamut_fraction;
  stats.wide_gamut_pixels = wide_count;
  stats.wide_gamut_eligible_pixels = lit_count;
}

}  // namespace hyperdr
