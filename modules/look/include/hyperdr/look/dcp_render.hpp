#pragma once
#include "hyperdr/image/image.hpp"
#include "hyperdr/image/dcp_profile.hpp"

namespace hyperdr {
struct LookOptions;
// Scene-linear P3 from the DCP camera transform, before gamut compression.
// Returns display-referred linear P3 SDR. This uses the DNG SDK sample render
// baseline (ACR3 fallback), not Lightroom's proprietary process version.
[[nodiscard]] FloatImage render_dcp_base(const FloatImage& scene_linear_p3,
    const DcpRenderContext& context, float exposure_ev = 0.0F);
// Explicit display-referred adjustments after DCP development. Contrast 1 and
// vibrance 0 preserve the profile exactly; pop remains an HDR-only control.
void apply_dcp_adjustments(FloatImage& base, const LookOptions& look);
}  // namespace hyperdr
