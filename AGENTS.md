# Notes for coding agents

Branch `refactor/multiplatform` is migrating HyperDR to native Apple apps. The
planning documents live in `docs/`, which is ignored by Git, so they are not in
this checkout. This file summarizes what they decide.

## Decisions that are settled

- HyperDR targets iPhone, iPad and Mac (user decision, 2026-10-21; this
  replaces the earlier Mac-only scope). The Mac app stays native SwiftUI, not
  Mac Catalyst, on Apple Silicon. Core packages (edit recipe, GPU render
  graph, export planning) must not depend on AppKit or UIKit. Windows stopped
  at commit `6949167` on `main`; Android is out of scope.
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
  2026-10-20 (last visible at `5cd997fd`). P7-4 removes the CLI, schema,
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
| `apps/apple/HyperDRiOS` | iOS/iPadOS target (UI redesign, 2026-10-21). `Home/`: the system library embedded as an inline `PhotosPicker` (no library of our own, no edits kept between photos: a tap opens the editor, closing it comes back). The picker's Photos | Collections switch is its own (centred in its top row at compact width, at the top of its sidebar at regular width; no API moves it or picks its tab), and Collections already holds albums and media types, so there is no filter of ours. Settings is a glass button at the top trailing corner, a layer in the picker's top row (the picker's search is off, since its field takes that corner on iPad); one glass bar at the bottom holds named buttons: Open from Files, and Exports once a version exists. Both are layers, not toolbars: content runs under a toolbar and the picker's remote view then takes its touches, all of them on iPad in landscape. `Settings/`: the app's name and tagline (where the subscription's state and Restore Purchases go), the LUT library (`LUTLibraryList`, which the editor's sheet also wraps), the exports kept and Clear, version, acknowledgements from the bundled `THIRD_PARTY_NOTICES.md`, and the privacy note. `History/`: the export history on Kit's `SessionStore.exportHistory` (the versions kept across photos, by day; a version shows the file itself in HDR, what was written and the adjustments it was written with, and can be shared, saved to Files or deleted), drag and drop on iPad. `App/EditingSession` owns the scene's `RecipeEditor`, export model, frame settings and capture facts; each photo is copied into `tmp/Imported/` (`ImportedPhoto`). `Editor/`: the editor as a full-screen cover with a Liquid Glass toolbar laid out as in Photos (close and undo/redo leading; the more menu, which holds Adjusted / Original / Split, and Export trailing) over a `UIView` + `CAMetalLayer` canvas drawn by the shared `DisplayCompositor` (`UIScreen` headroom, detail tiles, hold for original), with the Mac's badge at the photo's top right (`HDRBadge` on the edited photo, Original on the original); `EditorCanvas` draws the export's frame around the live canvas in the Frame pane. `Adjustments/`: `EditorLayout` by window width (iPad ≥ 1000 pt: the system `.inspector` with `AdjustmentInspector` and a Frame tab; narrower iPad and iPhone: the dock, standing on the right in iPhone landscape), the glass tab strip (named tabs: the groups, light and colour sharing one through `DockGroup`, plus Frame), HDR's power switch beside its source, switches as filled rings and other settings behind More, rings and ruler. `Frame/`: style miniatures, paper tones, caption options (dock and inspector forms). `Export/`: the export sheet (a row of destination tiles over a row of format tiles, `ExportFamily` folding the eight encodings into JPEG / HEIC / AVIF / TIFF; only the settings that apply, as menus, where changing one on a destination starts a custom format from it; the frame; what will be written above the main button; the last choice is kept in `UserDefaults`; then progress, Save to Files and Share) on Kit's `RecipeExportService` with its own `RenderEngine`; exports carry the frame through `FrameExportPlan`. `LUT/`: the LUT library on Kit's `LUTLibrary`; a look whose LUT is missing blocks export. Undo on the scene's undo manager; its own string catalogue; debug builds open a file at launch with `-HyperDROpen <path>` and start in landscape with `-HyperDRLandscape`. While exporting the screen stays awake; leaving the app cancels the run unless it is publishing or delivering. Links HyperDRDesign, HyperDRRecipe, HyperDRRender and HyperDRKit, so the engine xcframework needs its iOS slices (`test.py ios` builds them when missing; for Xcode alone, `bash scripts/build_xcframework.sh --platforms all`). Install steps: `apps/apple/README-iOS.md` |
| `apps/apple/Shared/Editor` | Shared by the Mac and iOS targets: `RecipeEditor` (recipe, undo steps, drag brackets, render pacing, AI state, detail regions for the host's `CanvasViewport`, the export capture, installing library LUTs), `RenderSession` on HyperDRRender, `EditorRendering` and its fake. Foundation, Observation, HyperDRRecipe and HyperDRRender only; tested by `Packages/HyperDREditorCore`, whose sources link to this directory |
| `apps/apple/Shared/Export` | Shared by the Mac and iOS targets: the editor's export capture in Kit's terms (`RecipeExportSnapshot`, `ExportPlanRequest`); `ExportLongEdge`, the custom format's size choices and the largest long edge that fits when memory blocks; `ExportReasonText`, Kit's typed notices and block reasons (`ExportNotice`, `ExportBlockReason`) in HyperDRDesign's shared words (`ExportReasonPhrase`, in the design package's catalogue). Kit's own catalogue keeps only the export stages |
| `apps/apple/Shared/Frame` | Shared by the Mac and iOS targets: the presentation frame's model (`FrameStyle`, `FrameSettings`, `CaptureFacts`), `FramePixelLayout`, the caption view (`FrameCaptionView`, `FramedPhoto`) and the export plan (`FrameExportPlan`, `FrameOverlayRenderer`). No catalogue keys: each app names styles and tones in its own catalogue |
| `apps/apple/Shared/AppIcon` | `HyperDR.icon`, the Icon Composer app icon of both targets (`ASSETCATALOG_COMPILER_APPICON_NAME = HyperDR`): two stacked instant prints, the front one a sun over mountains. It is a copy of `designs/hyperdr-icon-instant-scenes/s2-mountains/HyperDR.icon`; change it through that folder's `make_icons.py` and copy the bundle back |

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
- `Shared/Frame/` (Mac and iOS) captures a paper/shadow/caption snapshot. Core Image/Metal in
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
LUT looks: Kit's library records each LUT's input and output space, and choosing a
LUT writes them into `look.input` / `look.output` in the same undo step (a space the
photo's domain does not allow falls back to the declared default). The spaces are the
LUT's own: set in the library they change the look in use on that LUT, and chosen on
the look they are recorded in the library (`Shared/Editor/LibraryLUTs.swift`). Import
names spaces a file name declares (`LUTSpace.guess`); one file imported with a photo
open becomes its look, and removing the LUT in use drops the look (undoable). The look
pickers show each LUT on the photo (`LookPreviews`: small `keepsSource` renders that
never develop the photo again, only while a picker is on screen). Log spaces
(S-Log3 with S-Gamut3.Cine or S-Gamut3, V-Log, F-Log2, LogC3 EI800, LogC4, Canon
Log 3) are RAW-only inputs; they enter the LUT without the P3 fit, and an active
Log-input look develops the RAW scene-linear (`SourceOptions.sceneLinear`: boost 0,
the file's baseline exposure kept) so 18% grey lands on the curve's middle grey.
AI gain always infers from the Apple-boost development (`RenderSource.modelSourceID`),
so a Log look does not change it.
CustomExportFormat / ExportEncoding own export choices. E-07 (fast HEIC export)
is removed; HEVC uses the calibrated quality route (tests/quality).

Saving to Photos adds a new photo (`PhotoLibrarySaver.addPhoto`, add-only access) on Mac and iOS; replacing the original still waits for the user's Photos Lab result. Local quality and
fuzz gates remain outside CI; do not add a hosted runner.

Open, roughly in order (2026-10-21; details in
`docs/architecture/handoff-2026-10-21.md` §11): Render detail ROI, bounded
export tiles, native-tile RAW preview, the Kit export estimate on
`Packages/HyperDRRender/EXPORT_MEMORY.md` and the HEIF streaming sink are in.
The target is at least 110MP at full size on iPhone 17 Pro, for editing and
export; a smaller long edge is only a fallback. The estimate admits 110MP with
about 4 GiB of free process memory and not with 3 GiB.
61MP RAW opening, 1:1/pan and full-size Adaptive export, and the 60MP Sony HIF's
full-size HLG export have now succeeded on the physical iPhone 17 Pro. Use the
optimized `HyperDRiOS-Release` scheme for timing. Current measurements and remaining
110MP work are in `apps/apple/Packages/HyperDRRender/EXPORT_MEMORY.md`; real 110MP RAW
support is still unverified. Optimization was stopped at the user's request;
CPU remains default, the opt-in Metal experiment showed no HIF net benefit,
and a later identical-recipe RAW comparison differed by up to 9 decoded codes.
Its cause remains unresolved; do not claim universal pixel repeatability.
No further optimization is scheduled. The iOS/iPadOS UI was redesigned on
2026-10-21 (library, editor, frame, export, LUT library; see the `HyperDRiOS` row). Then: P7-3e (saving to the photo library, after the user's Photos
Lab run using `prototypes/photos-lab/PhotosLab.xcodeproj`, merged into this
branch), the iOS background host and the hands-on checks
in `docs/design/user-acceptance.md`.
`.github/workflows/ci.yml` runs only for `main`; its sanitizer job runs the
C ABI lifecycle and package tests through `ctest`. Run the test scripts with
`python3.12`.
