# Changelog

All notable user-visible changes to HyperDR are recorded here. The project uses
semantic versioning; dates use ISO 8601.

## Unreleased

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
