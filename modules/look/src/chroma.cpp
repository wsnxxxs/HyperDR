#include "hyperdr/look/rendition.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"
#include <algorithm>
#include <cmath>
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

}  // namespace hyperdr
