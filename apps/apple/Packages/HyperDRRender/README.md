# HyperDRRender (P7-0)

Shared macOS 26 / iOS 26 GPU processing, with no AppKit, UIKit, C ABI, or Swift C++ interop.
`HyperDRRecipe` contains only the v1 envelope and platform-independent parameter declarations.

```swift
let renderer = try RenderEngine()
let source = try await renderer.load(url) // caller holds the security scope
let preview = try await renderer.render(source, size: PixelSize(width: 2560, height: 1707))
try await renderer.renderStripes(source, rows: 256) { stripe in
    // Consume completed textures or RenderEngine.readPixels(stripe), then release them.
}
```

`RenderEngine` is an actor: decoding and GPU submission run away from the UI actor.
Cancellation is checked around decode and each GPU submission/stripe. System decoding and
already submitted GPU work finish before cancellation is reported; cancelled results are discarded.

## Source and pair contracts

* ImageIO opens raster sources (including HEIC/AVIF), exposes ISO/Apple auxiliary data, and
  classifies SDR / PQ or HLG HDR / dual. Core Image performs system HDR reconstruction.
* RAW uses CIRAWFilter AE-2 G2: boost 1, file boostShadow/baseline, exposure 0, LTM 0, EDR 1;
  contrast, sharpness, detail and noise-reduction overrides match the prototype. As-shot white
  balance, decoder selection and highlight recovery remain the system defaults. Lens correction
  is selectable. `rawSettings` records the actual settings.
* Source orientations are applied once. All public textures and readbacks have top-down rows;
  Core Image images exposed on `RenderSource` retain Core Image's bottom-left coordinates.
* Processing uses RGBA32Float extended-linear Display P3, SDR white 1. Negative values survive
  identity and sampling; P3 fitting is performed at the HDR split's SDR output boundary.
* Base and gain are separate textures; base alpha is alpha. Generated gain is R32Float log2 stops,
  linear P3, with zero offsets. `HDR = base * exp2(gain)`.
* An unchanged dual source is an **authored ISO/Apple pair**, not a max-channel split. Its base
  texture uses the native linear base gamut. Its gain texture contains original normalized
  **encoded** values, with 1 or 3 channels; `GainEncoding.authored` carries gamma/min/max,
  per-channel offsets, both headrooms, working-gamut selection, original auxiliary pixel bytes
  and the complete native metadata dictionary. No re-quantization or rounding is performed.
  A full-size unchanged render reuses the original textures, including the native gain resolution.
  Resized and stripe outputs resample them on the requested output grid; original assets remain
  on `RenderSource`. `PlanePixels.gainSize` can differ from its base size.
* ISO reconstruction applies decoded log2 gain **in its working gamut**:
  `alternate = (base + baseOffset) * exp2(gain) - alternateOffset`.
  `reconstructedHDR(source)` uses system HDR reconstruction, so three-channel gain, offsets,
  legacy Apple metadata and gamut selection are handled without a luma-ratio approximation.
* Any non-identity processing node makes a dual source enter the graph as reconstructed linear
  P3 HDR. Its final split becomes one channel with zero offsets and provenance `resplit`.
  Empty graphs and `IdentityNode` preserve authorship. P7-1 nodes must accurately declare
  `isIdentity` for default settings and include all effective parameters in `cacheKey`.

## Graph, caching and limits

`RenderNode` declares parameters, cache identity and input region requirements. The scheduler
walks regions backwards, renders the required halo, and crops the final stripe. The only
initial nodes are identity and AE-3 max-channel HDR split (including its P3 Oklab fit). HDR and
RAW sources automatically split at graph output. SDR identity produces zero gain.

Metal source is a copied package resource, compiled once per engine with safe math. The three
compute pipelines and one RGBAf CIContext are reused. No unverified Apple adjustment filter is
included. `DoubleReference` independently implements identity, split/fitting and ISO reconstruction;
it also carries AE-3's double grading formulas for P7-1.

The engine caches one opened source (file URL, size, modification date and RAW options), its
materialized RAW/raster texture, one optional dual HDR reconstruction, and one full output.
`clearCaches()` drops these and CI intermediates. A render supplied by the caller remains alive
until the caller releases it. Exposed textures are read-only to consumers. Stripe rendering
releases full-output cache and allocates only stripe/halo intermediates, but **source textures
remain resident**. Decode tiling, memory admission and background export belong to P7-3;
source texture dimensions still obey the device's Metal limits.

## Verification

Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and a private `TMPDIR`.
Run `python3 scripts/fetch_test_fixtures.py` at the repository root for the licensed RAW test.
Then `swift test --package-path apps/apple/Packages/HyperDRRender` and the equivalent Recipe
command. Tests require host Metal and system image codec services; a restricted process that
cannot enumerate a GPU reports `metalUnavailable` instead of skipping correctness checks.

Seven Render tests cover identity/negative values, split vs CPU double and resized stripes,
repeat rendering on the same/new contexts, TIFF orientation/cache, system-authored ISO
passthrough/reconstruction/resplit, RAW G2 and cache, and three-channel offsets/cancellation.
Recipe has one v1 serialization test. These are small contract checks, not an exhaustive format
or parameter matrix. The expanded same/new-context/cross-process/load determinism gates for
future nodes belong to P7-1; AE-3 already established those for the source split prototype.

Both packages were built with `xcodebuild -scheme HyperDRRender` for
`generic/platform=iOS` and `generic/platform=iOS Simulator` with signing disabled.
No App or existing Kit/engine code is changed here.

The JPEG decoder investigation and its numeric controls are in
[Research/README.md](Research/README.md). The approximately 14-code old/new source
difference is reproduced before the GPU graph. ICC is below 0.036 10-bit code;
IDCT differs by one 8-bit code per original Y/Cb/Cr plane, with additional
interpolation/matrix and integer-rounding effects. No decoder correction is applied.
