#pragma once

// Rendering a linear Display-P3 image into an SDR base plus a gain map.
//
// Two renderers implement this: `kPhotographic` (the default perceptual
// pipeline) and `kNeutral` (the earlier renderer, kept as a stable comparison
// and rollback path). Both produce the same result type, so nothing downstream
// -- encoder, verifier, or report -- knows which one ran.

#include "hyperdr/gainmap/types.hpp"

namespace hyperdr {

[[nodiscard]] GainMapResult make_gain_map(const FloatImage& linear_p3,
                                          const GainMapOptions& options,
                                          const CaptureMetadata& capture = {});

// The two renderers, exposed for direct comparison in tests and for callers
// that have already decided which one they want.
[[nodiscard]] GainMapResult make_photographic_gain_map(
    const FloatImage& linear_p3, const GainMapOptions& options,
    const CaptureMetadata& capture);
[[nodiscard]] GainMapResult make_neutral_gain_map(const FloatImage& linear_p3,
                                                  const GainMapOptions& options);

}  // namespace hyperdr
