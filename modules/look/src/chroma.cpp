#include "hyperdr/look/rendition.hpp"
#include "hyperdr/foundation/math.hpp"
#include "hyperdr/image/color.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
namespace hyperdr {
namespace {
std::array<float, 3> render_chroma(float r, float g, float b,
    float source_y, float sdr_y, float hdr_y, float peak,
    const LookOptions& look, ColorGamut gamut, bool hdr_only) {
  if (!(source_y > kEpsilon && (hdr_only ? hdr_y : sdr_y) > 0.0F))
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
      0.28F * std::clamp(look.pop, 0.0F, 1.0F);
  const float white_amount =
      smoothstep(white_start, peak, hdr_y) * white_cap;
  for (float& value : chroma) value *= 1.0F - white_amount;

  // At the source's scale a channel has to stay below 1 / sdr_ratio for the SDR
  // rendition and below peak / hdr_ratio for the HDR one. The shared SDR
  // colour uses the lower bound; an independent HDR colour uses its own target
  // gamut and bound. The fit keeps the luminance and the Oklab
  // hue and gives up only saturation, and returns a colour that already fits
  // unchanged, so the mapping is continuous where colours reach the bound.
  // (The tanh softener used before was not: values just below the bound were
  // multiplied by tanh(1), about 0.76, and a smooth sky crossing it showed a
  // contour.)
  const float sdr_ratio = sdr_y / source_y;
  const float hdr_ratio = hdr_y / source_y;
  float upper = std::numeric_limits<float>::infinity();
  if (!hdr_only && sdr_ratio > kEpsilon)
    upper = std::min(upper, 1.0F / sdr_ratio);
  if (hdr_ratio > kEpsilon) upper = std::min(upper, peak / hdr_ratio);
  const auto common = fit_linear_p3_to_gamut(
      source_y + chroma[0], source_y + chroma[1], source_y + chroma[2],
      upper, gamut);
  const float common_y = p3_luminance(common[0], common[1], common[2]);
  if (!(common_y > kEpsilon && std::isfinite(common_y)))
    return {0.0F, 0.0F, 0.0F};
  const float scale = (hdr_only ? hdr_y : sdr_y) / common_y;
  if (hdr_only)
    return {common[0] * scale, common[1] * scale, common[2] * scale};
  return {std::clamp(common[0] * scale, 0.0F, 1.0F),
          std::clamp(common[1] * scale, 0.0F, 1.0F),
          std::clamp(common[2] * scale, 0.0F, 1.0F)};
}
}  // namespace

std::array<float, 3> render_common_chroma(float r, float g, float b,
                                           float source_y, float sdr_y,
                                           float hdr_y, float peak,
                                           const LookOptions& look) {
  return render_chroma(r, g, b, source_y, sdr_y, hdr_y, peak,
                       look, ColorGamut::kDisplayP3, false);
}

std::array<float, 3> render_hdr_chroma(float r, float g, float b,
    float source_y, float hdr_y, float peak, const LookOptions& look,
    ColorGamut gamut) {
  return render_chroma(r, g, b, source_y, hdr_y, hdr_y, peak,
                       look, gamut, true);
}

}  // namespace hyperdr
