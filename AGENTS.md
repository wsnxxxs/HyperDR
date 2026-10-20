# Notes for coding agents

Branch `refactor/multiplatform` is migrating HyperDR to native Apple apps. The
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
  2026-10-20 (last visible at `50f734c6`). P7-4 removes the CLI, schema,
  panel-v1 adapter, C++ processing and ncnn; AI runs through Core ML in Render.
- New code is Apple/POSIX only, with no `_WIN32` branches.

## Layout

| Path | Contents |
|---|---|
| `modules/` | C++ engine; `modules/app` holds the engine facade, `modules/capi` the C ABI |
| `apps/apple/Packages/HyperDREngine` | Swift wrapper over the C ABI. Pure computations are synchronous; I/O, decoding and packaging are `async` on a dedicated queue and forward `Task` cancellation |
| `apps/apple/Packages/HyperDRKit` | Services: input formats, `SessionStore` (security-scoped bookmarks, cleanup, export versions), export planning and `RecipeExportService` |
| `apps/apple/Packages/HyperDRDesign` | Design tokens and controls, including the inspector controls; `Adjustments/` generates the adjustment controls from HyperDRRecipe's declarations (`AdjustmentPanel`, `AdjustmentInspector` for the Mac and the iPad sidebar, the touch slider), with their words in this package's catalogue |
| `apps/apple/HyperDR/Editor` | `EditorModel` / `CanvasModel`, the contract the views bind to, running on the real `HyperDRKit` services |
| `apps/apple/HyperDR/Views` | SwiftUI views; they only talk to the editor models |
| `apps/apple/HyperDR/macOS/Preview` | Metal EDR canvas: a compute pass rebuilds the frame, a second pass draws it at the canvas zoom and pan |
| `apps/apple/Shared/Canvas` | Shared by the Mac and iOS targets: `CanvasTransform`, the EDR layer setup and the display pass (`EDRDisplayPass`, `EDRDisplay.metal`) |
| `apps/apple/HyperDRiOS` | iOS/iPadOS target: PhotosPicker and Files (`fileImporter`) placed as in `p7-adjustments.md` §5.5, each photo copied into `tmp/Imported/` (`ImportedPhoto`) and edited through the shared `RecipeEditor` on HyperDRRender; a `UIView` + `CAMetalLayer` canvas drawn by the shared `DisplayCompositor` with `UIScreen` headroom, detail tiles when zoomed in, the effect mask while a masked control is dragged, and the comparison views of §5.4 (hold, Original / Adjusted / Split, the split divider); undo on the scene's undo manager; its own string catalogue; `Adjustments/` holds the iPhone adjustment bar, its ruler and the layout switch (P7-2a). `Export/` holds the minimal export sheet (P7-3b-U: destination or custom format with a long edge, a change to the largest long edge that fits when memory blocks, progress in Kit's stage words and cancel, Save to Files and Share) on Kit's `RecipeExportService` with its own `RenderEngine`; the photo's Kit session opens and hashes alongside the editor's decoding, and a run waits for it while preparing. `LUT/` holds the LUT library on Kit's `LUTLibrary` (import from Files, a plain list with removal); a look whose LUT is not in the library blocks export before it starts. While exporting the screen stays awake; leaving the app cancels the run unless it is publishing or delivering. Links HyperDRDesign, HyperDRRecipe, HyperDRRender and HyperDRKit, so the engine xcframework needs its iOS slices (`test.py ios` builds them when missing; for Xcode alone, `bash scripts/build_xcframework.sh --platforms all`). Install steps: `apps/apple/README-iOS.md` |
| `apps/apple/Shared/Editor` | Shared by the Mac and iOS targets: `RecipeEditor` (recipe, undo steps, drag brackets, render pacing, AI state, detail regions for the host's `CanvasViewport`, effect masks while dragging, the export capture, installing library LUTs), `RenderSession` on HyperDRRender, `EditorRendering` and its fake. Foundation, Observation, HyperDRRecipe and HyperDRRender only; tested by `Packages/HyperDREditorCore`, whose sources link to this directory |
| `apps/apple/Shared/Export` | Shared by the Mac and iOS targets: the editor's export capture in Kit's terms (`RecipeExportSnapshot`, `ExportPlanRequest`); `ExportLongEdge`, the custom format's size choices and the largest long edge that fits when memory blocks; `ExportReasonText`, Kit's typed notices and block reasons (`ExportNotice`, `ExportBlockReason`) in HyperDRDesign's shared words (`ExportReasonPhrase`, in the design package's catalogue). Kit's own catalogue keeps only the export stages |

## Building and testing

Everything here needs macOS with Xcode; there is no Linux build. Prefix Swift and
Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
unless Xcode is the selected developer directory. Python 3.10 or newer is
required.

```sh
python3 scripts/fetch_test_fixtures.py          # RAW samples used by the tests
python3 scripts/test.py native --build-dir build # engine: CMake preset macos-arm64-codecs
python3 scripts/test.py apple                    # xcframework, Swift packages, app build and tests, localization check
python3 scripts/test.py ios                      # iOS/iPadOS target: engine slices when missing, device and simulator builds, unsigned (needs Xcode's iOS platform)
```

- The C ABI is version 5. It accepts finished float32 planes through
  `hyperdr_package` / `hyperdr_package_rows`; rendering belongs to HyperDRRender.
  Keep package metadata, E5 zero-gain frames and bounded verification intact.
  `tests/capi` covers both static/shared handles, packaging and 512 KB stacks.
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
- `scripts/build_xcframework.sh` builds the macOS arm64 slice by default;
  `--platforms all` adds the iOS device and iOS simulator slices (deployment
  target 26.0). All hosts use the same writer library, so generate all three
  slices whenever iOS work needs it.
  Each slice's archive is checked for retired (L)GPL symbols by
  `check_licenses.py --archive-only` inside the build script, right after the
  archive is combined, so no slice can be built without the check and no caller
  has to remember it. The script rebuilds its output directory from scratch, so
  `build/xcframework` never holds a slice this run did not produce.
- Building the iOS slices needs `DEVELOPER_DIR` pointing at Xcode: vcpkg's
  `arm64-ios` and `arm64-ios-simulator` triplets read the iOS SDK through it, and
  with `xcode-select` on the Command Line Tools they fail with "iphoneos is not
  an iOS SDK".
- libtiff is a static *framework* on iOS (`tiff.framework/tiff`, linked as
  `-framework tiff`), not a `.a`; the xcframework script folds that binary into
  the combined archive, which is why the iOS archive still holds the TIFF
  symbols.
- Give each build directory its own vcpkg install root. A vcpkg manifest install
  removes the packages of other triplets from the install root it is given, so two
  presets sharing one root keep uninstalling each other's slices; changing the
  root also leaves stale imported-target paths in `CMakeCache.txt`, which fails at
  generate time until the build directory is cleared.

## Presentation frames

A frame (`hyperdr.frame/v1`) puts the photograph on a mat with an optional
shadow and caption. HyperDRRender composites the frame into finished export
planes. Frame pixels are SDR, with exactly zero gain; package enforces E5's
zero-code alignment, bounded mat readback and staged publication. Never draw
photo-dependent HDR content into the mat.

- `modules/image/src/frame.cpp` retains frame spec parsing and even-pixel layout;
  Kit's ExportPlanner uses `hyperdr_frame_layout`.
- App `Frame/` captures a paper/shadow/caption snapshot. Core Image/Metal in
  HyperDRRender composites it; no AppKit/UIKit enters the core package.
- The caption resource is a straight-alpha Display P3 overlay at its declared
  rectangle. Export history keeps recipe/resolved snapshots and an SDR thumbnail.
- `tests/quality/run.py --e5` uses synthetic finished planes through package,
  preserving the photo-error limits without the retired CLI/model producers.

## Current pipeline

Mac, iPhone and iPad editing uses RecipeEditor and HyperDRRender. ImageIO and
CIRAWFilter decode; Core ML supplies AI gain. RecipeExportService prepares lazy
ROI rows and calls the synchronous package row reader. The engine contains
writers, image/container readers, VideoToolbox codecs, bounded verification,
capability probing and frame layout; it has no CLI or image-processing graph.
InputFormats owns the input vocabulary; HyperDRRecipe owns adjustment declarations.
CustomExportFormat / ExportEncoding own export choices. E-07 (fast HEIC export)
is removed; HEVC uses the calibrated quality route (tests/quality).

Photos saving still waits for the user's Photos Lab result. Local quality and
fuzz gates remain outside CI; do not add a hosted runner.

Open, roughly in order (2026-10-21, end of phase; details in
`docs/architecture/handoff-2026-10-21.md` §10): review and merge
`wip/render-detail-memory` (`b719b4a7`: ROI detail, device texture limits,
faster export rows; contract in `Packages/HyperDRRender/EXPORT_MEMORY.md`),
then replace Kit's area-based Render terms in the export estimate with that
contract. The target is at least 110MP at full size on iPhone 17 Pro, for
editing and export; a smaller long edge is only a fallback. Functionality
comes first: the iOS/iPadOS UI will be redesigned, so iOS gets minimal
screens only (the P7-3c panel design is paused). Then: P7-3e (saving to
the photo library, after the user's Photos Lab run on `wip/photos-lab`), the
iOS background host and the hands-on checks in `docs/design/user-acceptance.md`.
`.github/workflows/ci.yml` runs only for `main`; its sanitizer job runs the
C ABI lifecycle and package tests through `ctest`. Run the test scripts with
`python3.12`.
