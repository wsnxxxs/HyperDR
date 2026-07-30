# Changelog

All notable user-visible changes to HyperDR are recorded here. The project uses
semantic versioning; dates use ISO 8601.

## Unreleased

## 0.3.1 - 2026-07-30

- Fixed adjustment-region masks so they refresh when the converter's exact
  curve arrives, stay off the original side of comparison views, and trigger
  only while the matching help question mark is hovered. Slider adjustment now
  remains an unobstructed live preview. The mask uses a lighter diagnostic
  magenta that remains visible over warm highlights.
- Fixed the histogram's brightness/RGB switch never reflecting its active
  state, and strengthened the selected capsule in both themes.
- Reduced mask-rendering overhead by caching the preview's linear luminance and
  reusing its image buffer. The panel labels the mask as an estimate because
  the final export also considers local contrast and noise.
- Fitted the preview frame to the decoded image's real aspect ratio, tightened
  the desktop settings rail, and made the histogram retain a stable readable
  height.

## 0.3.0 - 2026-07-28

- **Breaking.** Replaced the panel's front-end. The rewritten interface that
  was served at `/next` while it was built is now the panel itself, at `/`. The
  previous front-end is gone, and so is the `/next` route: a bookmark to it now
  returns 404 rather than a second copy of the panel. Nothing else about
  running HyperDR changes — the same address, the same access token, the same
  conversion behaviour and the same settings vocabulary.
- Rebuilt the interface as a darkroom: the image is the only lit surface, and
  the masthead, settings rail and output dock float around it as separate cards
  rather than sitting inside one full-width panel.
- Added a wipe comparison that drags between the original and the converted
  render, a result card that names what was written and warns when it has gone
  stale, and a dual-distribution histogram that shows the expansion alongside
  the source.
- Added a mask that shows which pixels a slider is currently acting on, so an
  adjustment that appears to do nothing can be seen to be acting outside the
  visible range rather than being broken.
- Fixed the theme toggle, which showed a sun in dark mode, and made the stored
  choice paint before first render so a reload no longer flashes the wrong
  theme.
- Hardened the panel's async lifecycles: an upload that is replaced mid-flight,
  a preview that returns after its image is dismissed, and a conversion polled
  across a reconnect no longer leave the interface reporting the previous
  image's state.
- Dropped the adjustment presets and the upload/convert/deliver phase strip.
  The presets wrote the same values the sliders already carry, and the phase
  strip repeated what the progress bar beside it was already showing.

## 0.2.2 - 2026-07-27

- Moved the TLS certificate pair to `%LOCALAPPDATA%\HyperDR\tls`, so a release
  archive extracted anywhere keeps serving trusted HTTPS. Earlier versions
  derived the path from the parent of the program directory, which silently
  fell back to HTTP once the folder was moved.
- Added a four-step certificate lookup: command-line arguments, environment
  variables, the managed store, then the pre-0.2.2 `Documents\HyperDR-Cert`
  location, which is copied forward once and never deleted.
- Warned at startup when the certificate has expired or when the current LAN
  address is missing from its subject alternative names, printing the exact
  re-issue command instead of quietly downgrading to HTTP.
- Replaced the one-line HTTP fallback warning with an explanation of every path
  that was searched, and made an explicit `-Certificate`/`-PrivateKey` that
  cannot be honoured exit with a readable message rather than a stack trace.
- Reported an unloadable certificate as a plain-language cause and continued
  over HTTP, where a mismatched key pair previously raised a traceback.
- Added `Setup-HTTPS.bat`, a one-time first-run step that installs `mkcert`
  through winget when needed, creates a certificate authority unique to the
  computer, issues the server certificate, and exports the public root
  certificate to the desktop with both required iPhone trust steps spelled out.
  No authority and no private key is shipped in a release archive.
- Re-issued the managed server certificate automatically, from the same local
  authority, when the router hands the computer a new address or the
  certificate is close to expiry, leaving the phone's installed root untouched.
  A certificate supplied by hand is reported on but never modified.
- Packaged the HTTPS setup and firewall scripts, and documented trusted HTTPS
  in `INSTALL.md` as an install step for true HDR rather than an optional
  extra.

## 0.2.1 - 2026-07-27

- Made browser previews viewport- and pixel-density-aware with bounded
  960/1440/2048 tiers, while keeping the JavaScript CPU renderer capped at
  1280 pixels.
- Added keyboard- and touch-operable 100%/200%/400% preview inspection with
  clamped panning, gesture conflict handling, and HDR-safe canvas scaling.
- Restored the histogram, clipping readouts, and zebra controls on mobile in a
  persistent disclosure, with read-only clipping summaries while collapsed.
- Surfaced the converter's latest log line during a run and stopped indefinite
  polling after a sustained connection failure.
- Consolidated light and dark colour tokens with CSS `light-dark()` and typed
  histogram properties, retaining explicit exceptions for theme icons and
  Canvas blend modes.
- Renamed the packaged Windows launcher to `Start.bat` and simplified the panel
  by removing the command-line copy surface.
- Made the front-end role-contract check understand the dynamically mounted
  quality controls.
- Made release packaging prepare and include the dual Main10/8-bit x265 runtime.
- Added an unpacked-package smoke test covering and self-verifying all six output
  encodings.
- Added the report schema, CLI exit-code documentation, and packaged-release
  quick start.
- Corrected RAW preview, startup protocol, licensing, and dependency
  documentation.

## 0.2.0 - 2026-07-20

- Added Adaptive HDR HEIC, Ultra HDR JPEG/R, PQ/HLG HEIC, and PQ/HLG AVIF
  conversion paths.
- Added the photographic renderer, structured schema-6 reports, resumable
  conversion, and the local browser panel.
