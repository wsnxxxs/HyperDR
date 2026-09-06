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

void render_full_resolution(const FloatImage& source, float exposure,
                            const std::vector<float>& local_grid,
                            std::uint32_t gain_width,
                            std::uint32_t gain_height,
                            float stored_gain_max, float stored_gamma,
                            float target_peak, const LookOptions& look,
                            bool clamp_srgb,
                            GainMapResult& result, BaseRenderCache* cache) {
  const ToneCurveParameters curve = build_tone_curve(look);
  const float pop = std::clamp(look.pop, 0.0F, 1.0F);
  const float clarity_amount = std::lerp(0.08F, 0.14F, pop);

  const bool reuse_base = cache && !cache->base.pixels.empty();
  result.base_linear = reuse_base ? cache->base : FloatImage(source.width, source.height, 3);
  if (cache && !reuse_base) cache->luminance.resize(static_cast<std::size_t>(source.width) * source.height);

  // Bind each grid to its dimensions once, outside the per-pixel loop: the
  // view's constructor is where the buffer-length precondition is checked.
  const GridView local_view(local_grid, gain_width, gain_height);
  const GridView gain_view(result.gain_map.pixels, gain_width, gain_height);
  const BilinearGridSampler sampler(gain_width, gain_height, source.width, source.height);

  std::vector<float> row_peak(source.height, 1.0F);
  std::vector<float> row_below(source.height, 0.0F);

  parallel_for_rows(source.height, [&](const std::uint32_t y) {
    float peak = 1.0F;
    float below = 0.0F;
    for (std::uint32_t x = 0; x < source.width; ++x) {
      const std::size_t base =
          (static_cast<std::size_t>(y) * source.width + x) * 3;
      const float r = finite_or_zero(source.pixels[base]) * exposure;
      const float g =
          finite_or_zero(source.pixels[base + 1]) * exposure;
      const float b =
          finite_or_zero(source.pixels[base + 2]) * exposure;
      const float scene = p3_luminance(r, g, b);
      float sdr;
      if (reuse_base) sdr = cache->luminance[static_cast<std::size_t>(y) * source.width + x];
      else {
        const float sdr_curve = render_tone_curve(scene, 1.0F, curve);
        const float local_average = sampler.sample(local_view, x, y);
        const float detail_ev = std::clamp(
            std::log2((sdr_curve + kEpsilon) /
                      (local_average + kEpsilon)),
            -1.5F, 1.5F);
        const float clarity_mask =
            smoothstep(0.025F, 0.16F, sdr_curve) *
            (1.0F - 0.65F * smoothstep(0.78F, 1.0F, sdr_curve));
        sdr = std::clamp(
            sdr_curve *
                std::exp2(detail_ev * clarity_amount * clarity_mask),
            0.0F, 1.0F);
        if (cache) cache->luminance[static_cast<std::size_t>(y) * source.width + x] = sdr;
      }
      const float gain_code =
          sampler.sample(gain_view, x, y);
      const float local_gain =
          stored_gain_max * decode_gain_code(gain_code, stored_gamma);
      const float hdr = sdr * std::exp2(local_gain);
      // Grade chroma from the base alone. Gain is a common RGB multiplier,
      // so fitting the base to the unit cube also fits every HDR channel to
      // the gain budget without changing colour as strength crosses zero.
      if (!reuse_base) {
        const auto base_rgb =
            render_common_chroma(r, g, b, scene, sdr, sdr, 1.0F, look);
        const auto output_rgb = clamp_srgb
                                    ? compress_linear_p3_to_srgb(
                                          base_rgb[0], base_rgb[1], base_rgb[2])
                                    : base_rgb;
        result.base_linear.pixels[base] = output_rgb[0];
        result.base_linear.pixels[base + 1] = output_rgb[1];
        result.base_linear.pixels[base + 2] = output_rgb[2];
      }
      peak = std::max(peak, hdr);
      if (scene <= curve.shoulder_input) {
        const float relative =
            std::abs(hdr - sdr) / std::max(sdr, kEpsilon);
        below = std::max(below, relative);
      }
    }
    row_peak[y] = peak;
    row_below[y] = below;
  });
  if (cache && !reuse_base) cache->base = result.base_linear;
  result.clamp_srgb = clamp_srgb;

  float rendered_peak = 1.0F;
  float below_knee_difference_max = 0.0F;
  for (std::uint32_t y = 0; y < source.height; ++y) {
    rendered_peak = std::max(rendered_peak, row_peak[y]);
    below_knee_difference_max =
        std::max(below_knee_difference_max, row_below[y]);
  }

  auto& stats = result.stats;
  stats.rendered_peak = rendered_peak;
  stats.headroom_utilization =
      target_peak > 1.0F
          ? std::clamp((rendered_peak - 1.0F) / (target_peak - 1.0F), 0.0F,
                       1.0F)
          : 0.0F;
  stats.below_knee_relative_difference_max = below_knee_difference_max;
}

}  // namespace hyperdr
