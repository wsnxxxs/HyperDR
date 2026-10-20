# Notes for coding agents

Branch `refactor/multiplatform` is migrating HyperDR to a native macOS app. The
planning documents live in `docs/`, which is ignored by Git, so they are not in
this checkout. This file summarizes what they decide.

## Decisions that are settled

- HyperDR targets iPhone, iPad and Mac (user decision, 2026-10-21; this
  replaces the earlier Mac-only scope). The Mac app stays native SwiftUI, not
  Mac Catalyst, on Apple Silicon. Core packages (edit recipe, GPU render
  graph, export planning) must not depend on AppKit or UIKit. Windows stopped
  at commit `a43d46a` on `main`; Android is out of scope.
- Direction approved on 2026-10-20 and 2026-10-21: image processing moves to a
  GPU render graph (Core Image plus our own Metal kernels) shared by preview
  and export; decoding moves to the system (ImageIO, `CIRAWFilter`); each
  writer is chosen per format between ImageIO and our own code; re-rendering
  the same settings must stay within one code value per pixel, and tests
  compare with tolerances, not bytes. The app has no photo library of its own
  and no Photos extension: it picks from the system photo library. The plan is
  in `docs/architecture/gpu-pipeline.md` and `product-vision.md` (ignored by
  Git); until it lands, the rules below describe the current code.
- The app is SwiftUI (AppKit only where SwiftUI cannot do the job) with a
  `CAMetalLayer` EDR preview, a Swift service layer (`HyperDRKit`) and the C++
  engine. Swift reaches the engine only through the C ABI in
  `modules/capi/include/hyperdr/hyperdr.h`; Swift C++ interoperability is not
  used.
- HEVC encoding and decoding use VideoToolbox only, and HEIF reading and
  writing are our own code. x265 is gone and HEIC exports are written by our
  own container code from VideoToolbox tiles. HEIC input, the write-time check
  of HEIC exports and diagnostics use our HEIF reader (`container/heif_reader`)
  and the VideoToolbox tile decoder. libheif and libde265 were deleted on
  2026-10-20 (P3b-5); the app bundle embeds no dylibs and carries no LGPL code.
- RAW is developed through `CIRAWFilter`; LibRaw is gone.
- The Python panel, LAN server, web front end and Tauri shell were deleted on
  2026-10-20 (last visible at `50f734c6`). The engine keeps the
  `command.adapter = "panel-v1"` request adapter; its name is unchanged.
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
| `apps/apple/Shared/Canvas` | Shared by the Mac and iOS targets: `CanvasTransform`, the EDR layer setup and the display pass (`EDRDisplayPass`, `EDRDisplay.metal`) |
| `apps/apple/HyperDRiOS` | iOS/iPadOS target (P7-0 shell): PhotosPicker and Files (`fileImporter`) placed as in `p7-adjustments.md` §5.5, a `UIView` + `CAMetalLayer` canvas with `UIScreen` headroom, a temporary Core Image loader (`TemporaryHDRSource`) until HyperDRRender lands; its own string catalogue. Links HyperDRDesign only. Install steps: `apps/apple/README-iOS.md` |

## Building and testing

Everything here needs macOS with Xcode; there is no Linux build. Prefix Swift and
Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
unless Xcode is the selected developer directory. Python 3.10 or newer is
required.

```sh
python3 scripts/fetch_test_fixtures.py          # RAW samples used by the tests
python3 scripts/test.py native --build-dir build # engine: CMake preset macos-arm64-codecs
python3 scripts/test.py apple                    # xcframework, Swift packages, app build and tests, localization check
python3 scripts/test.py ios                      # iOS/iPadOS target: device and simulator builds, unsigned (needs Xcode's iOS platform)
```

- Engine changes must keep CLI output byte-identical unless the change is
  intended; `tests/capi` compares the C ABI with the CLI byte for byte.
- A new worktree needs the test inputs: run `fetch_test_fixtures.py` there (or
  copy `build/fixtures/`) and copy `build/smoke/input.jpg`; the Kit and C ABI
  tests fail without them.
- Give concurrent native test runs separate `TMPDIR`s: `png_decode_test` still
  uses fixed temporary file names.
- App and Kit tests that need a small photo generate one with `TinyPhoto` in a
  private temporary directory. Opening files in the checkout from the test
  hosts has stalled for over a minute when the machine is busy.
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
  hands HyperDRKit an `ExportFrame` (K3), which writes `command.frame`. E5
  (framed gain maps put zero gain on a whole code; framed gain JPEGs use a
  quality-100 table) and E6 (staged export memory admission, no duplicate framed
  renditions) are in, and the frame toggle in the export panel is live. The
  panel's summary has a Frame row (none, the style, or a warning when the engine
  refuses the style for this photo) with "Change…", which swaps the export panel
  for the frame sheet and back. The summary, progress, result and history
  thumbnails of a framed export show the whole card (`Frame/FrameThumbnail.swift`:
  paper tone, the photo's SDR base at `layout.photo`, the caption band at
  `layout.caption`, no shadow).
- The frame sheet has Hold for SDR (`docs/design/frame-sheet.md`); the Instant
  style switches to a wide variant above 2.5:1 and is unavailable beyond about
  45:1.

## Status (2026-10-20, end of the seventh shift)

On this branch: the C ABI and its Swift wrapper; `EditorModel` on real
`HyperDRKit` services with the App Sandbox, Finder opening and restoring the
last photo; the M2 editor (controls, undo, scopes, canvas comparison, detail
regions and overlays) and its inspector views; RAW through `CIRAWFilter` with
cancellable opening (LibRaw removed); our own ISO 21496-1 gain-map JPEG reader
and writer (`iso-gainmap-jpeg`), with older gain-map JPEGs read through
ImageIO; the M3 export services and interface (save panel before rendering,
fixed folder kept inside the sandbox, history of the last twenty exports with
SDR thumbnails, LUT library, stage and time estimates; the equivalent CLI
command appears only in diagnostics, with placeholders); HEIC exports through
VideoToolbox and our own HEIF writer, with runtime encoder capabilities
(`encoder.main8/main10`); display headroom tracking and preview tracing (A3);
presentation frames with framed gain repair (E5), the export frame toggle and
framed thumbnails (F-T1); export memory admission (E6) whose estimate covers
raster, RAW and HEIC sources, external gain grids and LUTs (a LUT never counts
as retaining both renditions: `rendition_retention`); HEIC input, write-time
verification and diagnostics on our HEIF reader with VideoToolbox decoding
(P3b-1 to P3b-5, libheif and libde265 deleted); AVIF grids for canvases above
libaom's per-frame limit, with canvases beyond libavif's decode limits refused
at admission as `export_dimension_limit` (E8); external gain grids clipped per
axis to the base when packaging (E9); the parity batch (drag out and share,
missing-source notice and relinking, diagnostics, HEIF feature messages).

D1-b is in (2026-10-21): one set of default values, C1 (contrast 1, vibrance
0, pop 0, exposure bias 0, gain strength 1, headroom auto up to 3, expansion
start 0.25, area coverage 0.6); `source_defaults`, `unadjusted` and Kit
`applySourceIdentity` are gone; a fixed headroom without `headroom_max` raises
the ceiling to match. P7-0 is in: `HyperDRRecipe` (28 adjustment declarations
and recipe v1), `HyperDRRender` (system sources, GPU graph, double-precision
reference), the `HyperDRiOS` target with the EDR display pass shared through
`apps/apple/Shared`, and `python3 scripts/test.py ios`.

Open, roughly in order: the P7
plan (GPU render graph, system decoding, iPhone and iPad), whose prototype is
`wip/ae2-spike` = `4acec719` and which replaces AE-1 (RAW now follows
`CIRAWFilter`'s own development, `docs/research/ae2-apple-raw-ci.md`); two
experiments the plan waits on: a writer comparison (ImageIO versus our own
writers) and writing an edited HDR HEIC back to the photo library; P3b-6 (five
minutes of fuzzing per target, in the background, and acceptance); P3a-2
(encoder quality, including the photo-area errors E5 froze as non-regression
cases, and E-07; run locally, no self-hosted runner); the hands-on checks in
`docs/design/user-acceptance.md`.
