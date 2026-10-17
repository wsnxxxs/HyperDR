# Notes for coding agents

Branch `refactor/multiplatform` is migrating HyperDR to a native macOS app. The
planning documents live in `docs/`, which is ignored by Git, so they are not in
this checkout. This file summarizes what they decide.

## Decisions that are settled

- Target macOS 26 on Apple Silicon (arm64) only. iPhone and iPad are postponed;
  do not design for them. Windows stopped at commit `a43d46a` on `main`;
  Android is out of scope.
- The app is SwiftUI (AppKit only where SwiftUI cannot do the job) with a
  `CAMetalLayer` EDR preview, a Swift service layer (`HyperDRKit`) and the C++
  engine. Swift reaches the engine only through the C ABI in
  `modules/capi/include/hyperdr/hyperdr.h`; Swift C++ interoperability is not
  used.
- HEVC encoding and decoding will use VideoToolbox only, and HEIF reading and
  writing will be our own code; x265, libheif and libde265 are being removed.
- The Python panel, LAN server, web front end and Tauri shell are kept only as
  behaviour references until the SwiftUI app reaches parity, then deleted.
- New code is Apple/POSIX only, with no `_WIN32` branches.

## Layout

| Path | Contents |
|---|---|
| `modules/` | C++ engine; `modules/app` holds the engine facade, `modules/capi` the C ABI |
| `apps/apple/Packages/HyperDREngine` | Swift wrapper over the C ABI. Pure computations are synchronous; I/O, decoding, rendering and export are `async` on a dedicated queue and forward `Task` cancellation |
| `apps/apple/Packages/HyperDRKit` | Services: edit defaults, input formats, `SessionStore` (security-scoped bookmarks, cleanup, export versions), `PreviewService` |
| `apps/apple/Packages/HyperDRDesign` | Design tokens and controls, including the inspector controls |
| `apps/apple/HyperDR/Editor` | `EditorModel` / `CanvasModel`, the contract the views bind to. They still use fake services; wiring them to `HyperDRKit` is the next step |
| `apps/apple/HyperDR/Views` | SwiftUI views; they only talk to the editor models |
| `apps/apple/HyperDR/macOS/Preview` | Metal EDR canvas: a compute pass rebuilds the frame, a second pass draws it at the canvas zoom and pan |
| `apps/panel/web` | Web front end, the reference for features and default values |

## Building and testing

Everything here needs macOS with Xcode; there is no Linux build. Prefix Swift and
Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
unless Xcode is the selected developer directory. Python 3.10 or newer is
required.

```sh
python3 scripts/fetch_test_fixtures.py          # RAW sample used by the tests
python3 scripts/test.py native --build-dir build # engine: CMake preset macos-arm64-codecs
python3 scripts/test.py apple                    # xcframework, Swift packages, app build and tests, localization check
```

- Engine changes must keep CLI output byte-identical unless the change is
  intended; `tests/capi` compares the C ABI with the CLI byte for byte.
- Every engine entry point must run on a thread with a 512 KB stack
  (`tests/capi/small_stack.c`).
- User-visible strings go in `apps/apple/HyperDR/Resources/Localizable.xcstrings`
  (English and Simplified Chinese). `scripts/check_apple_i18n.py` rejects
  missing or unused keys and hard-coded Chinese in views.
- Requests produced by `normalize_options` carry `command.adapter = "panel-v1"`,
  which selects the panel's three-decimal rounding. Keep it when editing such a
  request; plain requests keep full precision.

## Presentation frames

A frame (`hyperdr.frame/v1`) puts the photograph on a mat with an optional print
shadow and caption. The frame must stay SDR: `frame_image` writes every frame
pixel from the spec alone into both renditions, so every gain-map writer stores
zero gain there (`frame_gain_test` checks all five packaging paths). Do not
draw anything into the frame that depends on the photo's HDR pixels.

- Engine: `modules/image/src/frame.cpp` (spec, even-pixel layout, compositing);
  export places it in `batch.cpp` after grading, before packaging. Model and
  external gain maps are then repackaged as an authored pair. CLI `--frame`,
  request `command.frame`, `hyperdr_frame_layout` / `frame-layout`.
- App: `HyperDR/Frame/` (styles, tones, caption typography, Exif via ImageIO,
  overlay renderer, `FrameExportPlan`) and `HyperDR/Views/Frame/` (the sheet).
  The caption overlay is a straight-alpha Display P3 PNG exactly the size of
  the layout's caption band; `FrameCaptionView` draws both preview and overlay.
- Still to do: A2 implements `EditorServices.captureFacts` (read inside the
  photo's security scope) and must set `document.pixelSize` to the full-size
  oriented dimensions the layout uses; M3 calls `FrameExportPlan.make` with the
  export's own pixel size and sets `command.frame`. The SDR comparison
  (press-and-hold) in the design is not built. On iPhone the same views run
  inside a full-screen sheet; `FramePreviewCanvas` needs a UIKit counterpart.
- The Swift side was written without Xcode and has not been built: expect
  compile fixes on first build.

## Status (2026-10-18)

Done: the C ABI and its Swift wrapper, the editor view-model contract with fake
services, localization, the main window, canvas overlays, inspector control
styles, `HyperDRKit` sessions and previews, and the two-pass Metal canvas.

Next, in order:

1. Connect `EditorModel` to `HyperDRKit`.
2. Turn on the App Sandbox; opening from Finder; restoring the last photo on launch.
3. Coalesce slider changes to at most one render per display frame.
4. Compare EDR output with the Photos app.
5. Export, models, LUTs, camera and lens profiles.
6. VideoToolbox HEVC encoding and the new HEIF writer.

The Metal canvas (`1488899`) and the inspector control styles (`5b0edd6`,
`defc236`) have not had an independent review yet.
