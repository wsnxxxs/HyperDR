#pragma once

namespace hyperdr {

// One place for the version that the CLI banner, the run report, the Exif
// Software tag, and the resumable-batch fingerprint all have to agree on.
inline constexpr char kVersion[] = "1.0.0";

// Resume sidecars use this separate revision because a renderer change can
// invalidate an existing output without being a user-visible product release.
// Increment it whenever the encoded bytes can change while the settings table
// and public version remain unchanged.
inline constexpr int kRenderPipelineRevision = 2;

}  // namespace hyperdr
