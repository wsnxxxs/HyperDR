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
- HEVC encoding and decoding use VideoToolbox only, and HEIF reading and
  writing are our own code. x265 is gone and HEIC exports are written by our
  own container code from VideoToolbox tiles; libheif and libde265 remain only
  for reading HEIF until our own reader (P3b) replaces them.
- RAW is developed through `CIRAWFilter`; LibRaw is gone.
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
| `apps/apple/HyperDR/Editor` | `EditorModel` / `CanvasModel`, the contract the views bind to, running on the real `HyperDRKit` services |
| `apps/apple/HyperDR/Views` | SwiftUI views; they only talk to the editor models |
| `apps/apple/HyperDR/macOS/Preview` | Metal EDR canvas: a compute pass rebuilds the frame, a second pass draws it at the canvas zoom and pan |
| `apps/panel/web` | Web front end, the reference for features and default values |

## Building and testing

Everything here needs macOS with Xcode; there is no Linux build. Prefix Swift and
Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
unless Xcode is the selected developer directory. Python 3.10 or newer is
required.

```sh
python3 scripts/fetch_test_fixtures.py          # RAW samples used by the tests
python3 scripts/test.py native --build-dir build # engine: CMake preset macos-arm64-codecs
python3 scripts/test.py apple                    # xcframework, Swift packages, app build and tests, localization check
```

- Engine changes must keep CLI output byte-identical unless the change is
  intended; `tests/capi` compares the C ABI with the CLI byte for byte.
- A new worktree needs the test inputs: run `fetch_test_fixtures.py` there (or
  copy `build/fixtures/`) and copy `build/smoke/input.jpg`; the Kit and C ABI
  tests fail without them.
- Give concurrent native test runs separate `TMPDIR`s: `png_decode_test` still
  uses fixed temporary file names.
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

- Engine: `modules/image/src/frame.cpp` (spec, layout with the photo at an even origin on an even canvas, compositing);
  export places it in `batch.cpp` after grading, before packaging. Model and
  external gain maps are then repackaged as an authored pair. CLI `--frame`,
  request `command.frame`, `hyperdr_frame_layout` / `frame-layout`.
- App: `HyperDR/Frame/` (styles, tones, caption typography, Exif via ImageIO,
  overlay renderer, `FrameExportPlan`) and `HyperDR/Views/Frame/` (the sheet).
  The caption overlay is a straight-alpha Display P3 PNG exactly the size of
  the layout's caption band; `FrameCaptionView` draws both preview and overlay.
- `EditorServices.captureFacts` reads the photo inside its security scope and
  `document.pixelSize` is the full-size oriented size the layout uses. Export
  hands HyperDRKit an `ExportFrame` (K3), which writes `command.frame`; the
  frame toggle in the export panel stays disabled until the frame gain and
  export memory work (E5, E6) is done. The SDR comparison (press-and-hold) in the design is not built.

## Status (2026-10-19)

On this branch: the C ABI and its Swift wrapper; `EditorModel` on real
`HyperDRKit` services with the App Sandbox, Finder opening and restoring the
last photo; the M2 editor (controls, undo, scopes, canvas comparison, detail
regions and overlays) and its inspector views; RAW through `CIRAWFilter` with
cancellable opening (LibRaw removed); our own ISO 21496-1 gain-map JPEG reader
and writer (`iso-gainmap-jpeg`), with older gain-map JPEGs read through
ImageIO; the M3 export services and interface (save panel before rendering,
fixed folder kept inside the sandbox, history of the last twenty exports, LUT
library, stage and time estimates; the equivalent CLI command appears only in
diagnostics, with placeholders); HEIC exports through VideoToolbox and our own
HEIF writer, with runtime encoder capabilities (`encoder.main8/main10`);
display headroom tracking and preview tracing (A3); presentation frames.

Open: the frame export toggle (E5 frame gain, E6 export memory); our own HEIF
reader replacing libheif and libde265 (P3b); HEIC decoding through
VideoToolbox (V5); `png_decode_test` temporary file isolation; removing
`EditorModel.exportFileURL`, which no view uses any more; the comparison with
the Photos app on a real display and the other hands-on checks in
`docs/design/user-acceptance.md`; deleting the Python panel, LAN server, web
front end and Tauri shell once the app reaches parity.
