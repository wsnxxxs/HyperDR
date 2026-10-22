<p align="center">
  <img src=".github/readme/icon.svg" width="104" alt="HyperDR icon">
</p>

<h1 align="center">HyperDR</h1>

<p align="center">
  <b>HDR photo editing, end to end.</b><br>
  iPhone · iPad · Mac
</p>

<p align="center">
  English&nbsp;&nbsp;·&nbsp;&nbsp;<a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="https://github.com/wsnxxxs/HyperDR/releases">Download for Mac</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="apps/apple/README-iOS.md">Build for iPhone &amp; iPad</a>&nbsp;&nbsp;·&nbsp;&nbsp;<a href="CHANGELOG.md">What’s new</a>
</p>

<br>

<p align="center">
  <img src=".github/readme/ipad-en.png" width="100%" alt="HyperDR editing a RAW night photo on iPad, with the HDR controls in the inspector">
</p>

<br>

Most editors flatten an HDR photo into SDR the moment you touch it. HyperDR
keeps the light above white — from the camera file to the exported photo — and
shows it at your display’s real brightness while you edit.

<br>

## Why HyperDR

### HDR is the subject, not an afterthought

The canvas is an EDR Metal layer, so highlights glow on screen exactly as far as
your display allows. HDR has its own source and its own controls:

- **Captured** — the highlights your camera actually recorded, from RAW, HIF, HEIC or gain-map files.
- **+ Expand** — stretch what is there into more headroom.
- **+ AI** — an on-device Core ML model predicts highlights the file never stored.

Controls marked *Affects HDR only* shape the highlights without touching the SDR
picture underneath, so both versions stay right.

### What you approve is what is written

<p align="center">
  <img src=".github/readme/pipeline-en.svg" width="100%" alt="Pipeline: inputs are decoded, the recipe drives one GPU render graph, which feeds both preview and export">
</p>

Preview and export run through the same GPU render graph — Core Image plus our
own Metal kernels, in linear Display P3 with extended range. There is no
separate export engine that reinterprets your edit. Each file is read back and
checked before it is handed to Files, Photos or the share sheet.

### Exports that look right on every screen

<p align="center">
  <img src=".github/readme/gainmap-en.svg" width="100%" alt="An SDR base plus a gain map makes an adaptive HDR photo">
</p>

Adaptive HDR stores a finished SDR picture plus a gain map (ISO 21496-1). An
ordinary screen shows the SDR picture you graded; an HDR screen lifts the
highlights as far as it can. No guessing, no washed-out fallback.

| Output | Encoding |
|---|---|
| **Adaptive HDR HEIC** | SDR base + ISO 21496-1 gain map, HEVC |
| **Gain-map JPEG** | SDR base + ISO 21496-1 gain map |
| **HDR HEIC · AVIF** | PQ or HLG, 10-bit |
| **SDR** | JPEG · HEIC · TIFF |

Pick a destination — Web, Social or Photos — and HyperDR chooses the format,
size and quality; change any setting to make a format of your own.

### Looks from measured film, LUTs that know their colour space

- **Film** — Kodak Portra 400, Gold 200, Kodachrome 64, Vision3 500T and Fujifilm Velvia 100, emulated from measured data: exposure, development and, for negatives, the print. Grain, halation and the antihalation layer are modelled, not overlaid.
- **LUTs** — every LUT remembers its input and output space. Camera Log curves (S-Log3, V-Log, F-Log2, LogC3, LogC4, Canon Log 3) are fed from a scene-linear RAW development, so middle grey lands where the LUT expects it.
- **Strength** mixes in linear light, and a look changes the SDR base while the HDR highlights are kept.

### Frames for showing the work

<p align="center">
  <img src=".github/readme/iphone-en.png" width="100%" alt="HyperDR on iPhone: the HDR controls, a Gallery frame with an EXIF caption, and the export sheet">
</p>

Gallery, Label, Story, Hairline and Instant mats, in five paper tones, with an
optional caption from the photo’s own EXIF. The paper is written with exactly
zero gain, so the mat never glows on an HDR display — only the photograph does.

### Edits that don’t drift

RAW files are developed by Apple’s `CIRAWFilter`, and the exact decoder version
is saved with your edit. Opening the photo again — on another device, after an
OS update — develops it with that same decoder, never a newer or older one. If it is ever unavailable,
HyperDR says so instead of quietly showing you something different.

### Private, native, self-contained

- Photos are processed on the device. HyperDR reads only the photos you pick in the system picker and has no library of its own.
- SwiftUI on every platform, Liquid Glass on iOS and iPadOS, no Catalyst.
- HEIF is read and written by HyperDR’s own container code, with HEVC through VideoToolbox. The app embeds no dynamic libraries and no (L)GPL code.
- Built for large files: 61 MP RAW and 60 MP HIF photos open, pan at 1:1 and export at full size on iPhone 17 Pro.

<br>

## Formats

|  | |
|---|---|
| **Opens** | Camera RAW that Apple’s decoder supports (DNG, ARW, CR3, NEF, RAF, ORF, RW2 …) · HEIC / HEIF / HIF · AVIF · JPEG, including gain-map JPEG · PNG · TIFF |
| **Writes** | Adaptive HDR HEIC · gain-map JPEG · PQ / HLG HEIC and AVIF · SDR JPEG, HEIC and TIFF |
| **Saves to** | Files · Photos (as a new photo) · Share sheet |

## Get HyperDR

**Mac** — download the latest build from
[Releases](https://github.com/wsnxxxs/HyperDR/releases), unzip it and move
`HyperDR.app` to Applications. The build is ad-hoc signed and not notarised: if
macOS blocks the first launch, choose *Open Anyway* in System Settings → Privacy
& Security.

**iPhone and iPad** — build from source with Xcode; see the
[installation notes](apps/apple/README-iOS.md).

Requires iOS / iPadOS 26 or macOS 26 on Apple silicon. RAW decoder 9 needs
version 27; older systems use the default decoder Apple provides.

> HyperDR 0.5.0 is a pre-release. Full-size 110 MP RAW on iPhone is still being
> verified, and iOS does not yet continue an export in the background.

<br>

## For developers

<details>
<summary><b>Architecture</b></summary>
<br>

| Layer | Where | What it does |
|---|---|---|
| App | `apps/apple/HyperDR`, `apps/apple/HyperDRiOS` | SwiftUI for Mac, and iPhone / iPad |
| Shared editor | `apps/apple/Shared` | `RecipeEditor`, EDR canvas, export capture, frames |
| Recipe & render | `Packages/HyperDRRecipe`, `Packages/HyperDRRender` | The edit as data; the GPU render graph (Core Image + Metal, Core ML) |
| Services | `Packages/HyperDRKit` | Input formats, sessions, export planning and `RecipeExportService` |
| Engine | `modules/` | C++ writers, HEIF / image readers, VideoToolbox codecs, bounded verification — reached only through the C ABI in `modules/capi/include/hyperdr/hyperdr.h` |

Core packages do not depend on AppKit or UIKit. Swift calls the C ABI directly,
without C++ interoperability.

</details>

<details>
<summary><b>Build and test</b></summary>
<br>

Needs macOS with Xcode (iOS and Metal toolchains), CMake, Ninja, vcpkg and
Python 3.12. Dependency versions are pinned in `vcpkg.json`; give each build
directory its own vcpkg install root.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR="$(mktemp -d /tmp/hyperdr-build.XXXXXX)"
python3.12 scripts/fetch_test_fixtures.py
cmake --preset macos-arm64-codecs -B build -DPython3_EXECUTABLE="$(command -v python3.12)"
python3.12 scripts/test.py native --build-dir build   # engine
python3.12 scripts/test.py apple                      # xcframework, Swift packages, Mac app, localisation
python3.12 scripts/test.py ios                        # unsigned iPhone / iPad device and simulator builds
```

`bash scripts/build_xcframework.sh --platforms all` builds all three arm64
slices and checks each archive for (L)GPL symbols. Local quality gates are in
[tests/quality](tests/quality/README.md); parser fuzz targets are opt-in under
`tests/fuzz`.

</details>

<br>

## License

HyperDR is dual-licensed under the [GNU AGPL v3.0](LICENSE) or a commercial
license — see [LICENSING.md](LICENSING.md). The HyperDR name and app icon are not
covered by either license. Third-party components keep their own licenses:
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

<br>

<p align="center">
  <sub>Copyright © 2026 Renhe Wang</sub>
</p>
