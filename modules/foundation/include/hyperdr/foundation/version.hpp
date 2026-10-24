#pragma once

namespace hyperdr {

// Product version shared by engine diagnostics, the C ABI and the Exif
// Software tag. Keep it aligned with the native apps and release metadata.
inline constexpr char kVersion[] = "0.5.3";

// Resume sidecars use this separate revision because a renderer change can
// invalidate an existing output without being a user-visible product release.
// Increment it whenever the encoded bytes can change while the settings table
// and public version remain unchanged.
inline constexpr int kRenderPipelineRevision = 27;

}  // namespace hyperdr
