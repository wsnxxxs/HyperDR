# Changelog

All notable user-visible changes to HyperDR are recorded here. The project uses
semantic versioning; dates use ISO 8601.

## Unreleased

- Added HDR input support, so every encoding HyperDR writes it can now also
  read. AVIF joins ARW, DNG, JPEG, PNG, HEIC and HEIF as an input format, and
  BT.2100 PQ and HLG files are decoded through the exact inverse of the transfer
  functions used to write them. 4:2:2 and 4:4:4 chroma are read as well as
  4:2:0, so an HLG 4:2:2 HEIF of the kind Sony's cameras produce converts to any
  of the six outputs with its highlight range intact.
- Added safe Exif import for JPEG, HEIC, AVIF and Ultra HDR inputs. Camera, lens,
  date, capture settings and orientation are carried through without inventing
  fallback Make tags. ISO in particular feeds the gain map's noise weighting.
- Fixed a rotated JPEG reporting its pre-rotation dimensions in the run report
  while the converted image used the rotated ones.
- Fixed 10-bit HEIC and AVIF images whose colour is described only by an ICC
  profile decoding around 64 times too dark.
- Replaced the panel's 8-bit sRGB JPEG preview intermediate with native
  linear-Display-P3 float32 SDR/HDR planes. Preview generation now calls the
  same photographic base, gain-map, and reconstruction code as export; the
  browser performs presentation only. Ultra HDR decode fallback is explicitly
  reported as degraded with `ultrahdr_decode_failed_sdr_fallback` instead of
  silently becoming an ordinary JPEG decode.
- Fixed conversion failing on images whose peak gain does not coincide with
  their brightest pixel. The ISO gain-map reader had begun requiring `gain_max`
  to equal the declared alternate headroom, which are different quantities, and
  because the encoder verifies the file it has just written the conversion
  aborted with an unrelated "failed semantic structure verification" message.
  Files written by 1.0.0 also began reporting as structurally invalid.
- Removed the `neutral` renderer. `--look` now accepts only `photographic`;
  `--look neutral` is rejected rather than silently mapped onto the survivor, so
  a stored preset or script that names it fails loudly. `--contrast`,
  `--vibrance`, `--pop` and `--headroom-max` are no longer silently ignored by a
  second renderer, and the note explaining that has been removed.

## 1.0.0 - 2026-08-06

- Added an explicit mathematical/model preview switch. The first model use
  performs inference, while later comparisons reuse the cached gain map
  instantly until the image or its decode changes.
- Added a model-only optimization-strength control and matched its effect in
  SDR, HDR and exported output without re-enabling mathematical look controls.
- Made the output histogram follow the spatial model gain and optimization
  strength, and removed the mathematical expansion marker in model mode.
- Smoothed model-preview gain sampling to remove visible grid blocks while
  keeping the external `.f32` model path independent from the mathematical
  exposure, tone, contrast and vibrance pipeline.
- Kept PyTorch outside the Windows package; model inference uses the configured
  Python installation and its existing CUDA/PyTorch environment.

## 0.3.2 - 2026-07-31

- Fixed managed HTTPS certificate checks to compare complete SAN IP addresses,
  so a previous address such as `192.168.1.100` cannot be mistaken for the
  current `192.168.1.10`. Certificate setup now also reports and stops on a
  failed private-key permission restriction instead of claiming it succeeded.
- Hardened panel access-token handling: newly generated tokens carry 128 bits
  of entropy, malformed non-ASCII credentials fail normally, and invalid cookie
  credentials share the login throttle without counting requests that supplied
  no credential.
- Fixed percent-encoded upload names being decoded twice.
- Made `thumbnail --quality` reject values outside its documented `1..100`
  range instead of silently clamping them.
- Aligned package and generated-schema version metadata with 0.3.2.

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
