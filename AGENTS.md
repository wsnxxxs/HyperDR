# Notes for coding agents

The native Apple app migration was merged into `main` for 0.5.0. The
planning documents live in `docs/`, which is ignored by Git, so they are not in
this checkout. This file summarizes what they decide.

## Decisions that are settled

- HyperDR targets iPhone, iPad and Mac (user decision, 2026-10-21; this
  replaces the earlier Mac-only scope). The Mac app stays native SwiftUI, not
  Mac Catalyst, on Apple Silicon. Core packages (edit recipe, GPU render
  graph, export planning) must not depend on AppKit or UIKit. Windows stopped
  at commit `6949167` on `main`; Android is out of scope. The first release
  requires iOS/iPadOS 27 and macOS 27 (user decision, 2026-10-23); every
  deployment target (Xcode, packages, CMake presets, vcpkg triplets) is 27.0.
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
| `apps/apple/HyperDRiOS` | iOS/iPadOS target (UI redesign, 2026-10-21). An iPad window of regular width gets the Studio in `Pad/` (iPad redesign, 2026-10-23; `docs/design/ipad-studio.md`); the iPhone, and an iPad window of compact width, get the screens below (`StudioRoot` and `EditorRoot` choose by the horizontal size class, so a resized window swaps the editor and keeps the edit). `Home/`: the iPhone's first screen, the system library embedded as an inline `PhotosPicker` (no library of our own, no edits kept between photos: a tap opens the editor, closing it comes back). The picker's Photos | Collections switch is its own (centred in its top row at compact width, at the top of its sidebar at regular width; no API moves it or picks its tab), and Collections already holds albums and media types, so there is no filter of ours. Settings is a glass button at the top trailing corner, a layer in the picker's top row (the picker's search is off, since its field takes that corner on iPad); one glass bar at the bottom holds named buttons: Open from Files, and Exports once a version exists. Both are layers, not toolbars: content runs under a toolbar and the picker's remote view then takes its touches, all of them on iPad in landscape. `Settings/`: the app's name and tagline (where the subscription's state and Restore Purchases go), the LUT library (`LUTLibraryList`, which the editor's sheet also wraps), the exports kept and Clear, Export Diagnostics, version, acknowledgements from the bundled `THIRD_PARTY_NOTICES.md`, and the privacy note. `Diagnostics/`: `DiagnosticLog` (each line to unified logging and to a file per launch, the last five kept under Application Support/Diagnostics, out of backups; `EditorLog` is mirrored into it), `MetricsCollector` (MetricKit's diagnostic and metric payloads as JSON) and `DiagnosticsReport` (a zip of a summary, this run's `OSLogStore` entries, the launch files and the payloads, shared from Settings). Log lines name stages, sizes, formats and error kinds, never file names or paths. `Resources/PrivacyInfo.xcprivacy` declares the required-reason APIs (UserDefaults CA92.1; file timestamps C617.1, 3B52.1; disk space E174.1, the free-space check before an export stages a RAW endpoint) and no data collection; `ITSAppUsesNonExemptEncryption` is NO (CryptoKit only hashes). `History/`: the export history on Kit's `SessionStore.exportHistory` (the versions kept across photos, by day; a version shows the file itself in HDR, what was written and the adjustments it was written with, and can be shared, saved to Files or deleted), drag and drop on iPad. `App/EditingSession` owns the scene's `RecipeEditor`, export model, frame settings and capture facts; each photo is copied into `tmp/Imported/` (`ImportedPhoto`). `Editor/`: the editor as a full-screen cover with a Liquid Glass toolbar laid out as in Photos (close and undo/redo leading; the more menu, which holds Adjusted / Original / Split, and Export trailing) over a `UIView` + `CAMetalLayer` canvas drawn by the shared `DisplayCompositor` (`UIScreen` headroom, detail tiles, hold for original), with the Mac's badge at the photo's top right (`HDRBadge` on the edited photo, Original on the original); `EditorCanvas` draws the export's frame around the live canvas in the Frame pane. `Adjustments/`: the dock (`EditorLayout`: under the canvas, standing on the right in iPhone landscape, the large one in a compact iPad window), the glass tab strip (named tabs in three capsules: HDR; Adjust, where light and colour share one tab through `DockGroup`, which also shows the film's grain and halation, Style, which keeps only the look and its strength, and Crop; then Frame), HDR's power switch beside its source, switches as filled rings and other settings behind More, rings and the ruler (a tape under a fixed needle). `Crop/`: the dock's Crop pane on `Recipe.geometry` (ratio, rotation, quarter turn, mirror, perspective on rings and the ruler); the canvas shows the whole photo with `Shared/Crop`'s box while it is open and the render applies the geometry everywhere else. `Frame/`: style miniatures, paper tones, caption options (the dock's form; the Studio's Frame tool reuses the tiles and tones). `Export/`: the export sheet (a row of destination tiles over a row of format tiles, `ExportFamily` folding the eight encodings into JPEG / HEIC / AVIF / TIFF; only the settings that apply, as menus, where changing one on a destination starts a custom format from it; the frame; what will be written above the main button; the last choice is kept in `UserDefaults`; then progress, Save to Files and Share; on the iPad a landscape lightbox page (`LightboxSizing`) with a live EDR preview of the framed export, `PadExportPreview`, beside the same column) on Kit's `RecipeExportService` with its own `RenderEngine`; exports carry the frame through `FrameExportPlan`. `LUT/`: the LUT library on Kit's `LUTLibrary`; a look whose LUT is missing blocks export. `Pad/`: the Studio. `Home/PadHome`: the picker (its search on, since nothing is laid over it) with HyperDR's own glass column beside it (Open from Files, the drop zone, the last six exports opening the history at that version, the LUT library, Settings), a shelf along the foot when the window is taller than wide. `Editor/`: `PadEditor` (toolbar: close, undo/redo; More, the panel button and a named Export), `PadLayout` (the panel stands on the right when the window is at least 960 pt wide and 1.15× wider than tall, else lies along the foot; it folds to its rail; the canvas never runs under it), `PadCanvasBar` (Adjusted / Split / Original, Fit ↔ 100 %, the screen's headroom), `PadExportPreview`. `Panel/`: `PadPanel` (glass: `PadToolRail` with HDR, Light, Color, Style, Detail, Crop and Frame, ⌘1 …, holding a tool bypasses its group; `PadHistogram` measured by `PadScopes` as the Mac measures its scopes; the tool's header with HDR's switch and the tool's reset; the photo's facts at the foot), `PadGroupControls`, `PadLookTool` (look grids shown on the photo), `PadCropTool`, `PadFrameTool`. `Controls/`: `PadSlider` (a 44 pt fill bar: relative drag that starts only sideways (`HorizontalPan`, so the panel still scrolls), fine-tune, default detent, double-tap reset, tap to type, long press for the menu and the control's help), switch, segment and menu rows. On the iPad, History and Settings are pages (the grid beside the version; the sections beside their content). Undo on the scene's undo manager; its own string catalogue; debug builds open a file at launch with `-HyperDROpen <path>` and start in landscape with `-HyperDRLandscape`. While exporting the screen stays awake; leaving the app cancels the run unless it is publishing or delivering. Links HyperDRDesign, HyperDRRecipe, HyperDRRender and HyperDRKit, so the engine xcframework needs its iOS slices (`test.py ios` builds them when missing; for Xcode alone, `bash scripts/build_xcframework.sh --platforms all`). Install steps: `apps/apple/README-iOS.md` |
| `apps/apple/Shared/Editor` | Shared by the Mac and iOS targets: `RecipeEditor` (recipe, undo steps, drag brackets, render pacing, AI state, detail regions for the host's `CanvasViewport`, the export capture, installing library LUTs), `RenderSession` on HyperDRRender, `EditorRendering` and its fake, `EditorLog` (opens, RAW decoder fallbacks, render and AI failures, as error kinds without paths; a host may mirror it). Foundation, Observation, os, HyperDRRecipe and HyperDRRender only; tested by `Packages/HyperDREditorCore`, whose sources link to this directory |
| `apps/apple/Shared/Crop` | Shared by the Mac and iOS targets: `CropLayout` (where the crop pane puts the photo, and the `GeometryDisplay` the compositor draws through) and `CropOverlay` (the crop box, its drag and, on the Mac, its cursors). The inspector form of the pane is HyperDRDesign's `GeometryInspector`; on the Mac the inspector's Adjust / Crop switch sets `EditorModel.isCropping` |
| `apps/apple/Shared/Scope` | Shared by the Mac and iOS targets: `ScopeAnalyzer` (histogram and waveform counts of a frame at full gain, on `ScopeScale`'s ruler) and `TextureReadback`. The Mac's inspector scopes and the iPad Studio's histogram measure with it; not in `HyperDREditorCore`, which has no design package |
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
- The iOS Simulator's ImageIO never applies a gain map when decoding to HDR
  (headroom 1.0 even for an iPhone's own HEIC, which a Mac reads as 4 to 6.6).
  `ExportVerification.systemAppliesGainMaps` skips the row path's
  `system_hdr_headroom` check there; check HDR readback on a Mac or a device.
- Every engine entry point must run on a thread with a 512 KB stack
  (`tests/capi/small_stack.c`).
- User-visible strings go in `apps/apple/HyperDR/Resources/Localizable.xcstrings`
  (English and Simplified Chinese). `scripts/check_apple_i18n.py` rejects
  missing or unused keys and hard-coded Chinese in views.
- `scripts/build_xcframework.sh` builds the macOS arm64 slice by default;
  `--platforms all` adds the iOS device and iOS simulator slices (deployment
  target 27.0). All hosts use the same writer library, so generate all three
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
CIRAWFilter decode; Core ML supplies AI gain. The apps require iOS/iPadOS 27 and macOS 27; RAW decoder 9 still depends on the camera and file.
Settings on Mac, iPhone and iPad offer Automatic, RAW 8 and RAW 9 for new
photos. Automatic selects decoder 9 when the system and file support it
(including `9.dng`), otherwise decoder 8 (`8.dng` for DNG); cameras without
either keep their supported older system default. Explicit RAW 8/9 requires
that exact generation and reports an unavailable version without fallback.
The exact version is stored in `Recipe.rawDecoderVersion`. In Automatic, a new
photo whose decoder 9 cannot decode retries 8 once (or the older default if 8 is unavailable), even if
the system default is itself 9, and records the successful version.
The preference does not reopen the current photo or rewrite saved recipes.
Saved recipes never downgrade. Old recipes without this field keep the system
default. An unavailable recorded version blocks decoding/export.
All RAW developments use an extended-linear sRGB CIContext, converting to extended
linear P3 at output: decoder 9 loses red with a P3/Rec.2020 working context.
Preview, ROI, look baseline and AI input share the recorded decoder. RecipeExportService prepares lazy
ROI rows and calls the synchronous package row reader. The engine contains
writers, image/container readers, VideoToolbox codecs, bounded verification,
capability probing and frame layout; it has no CLI or image-processing graph.
InputFormats owns the input vocabulary; HyperDRRecipe owns adjustment declarations.
Imported HDR gain-map photos keep their authored SDR endpoint through light/color edits.
ISO HDR reconstruction uses the same decoded gain pair as the original canvas; legacy
Apple maps use system reconstruction. Edited endpoints carry RGB gain with equal offsets
and global headroom, shared by preview, detail regions and export; never discard the SDR
endpoint and re-split HDR merely because exposure moves away from zero.
LUT looks: Kit's library records each LUT's input and output space, and choosing a
LUT writes them into `look.input` / `look.output` in the same undo step. A LUT whose
input the photo cannot supply is disabled, never relabelled as sRGB. The spaces are the
LUT's own: set in the library they change the look in use on that LUT, and chosen on
the look they are recorded in the library (`Shared/Editor/LibraryLUTs.swift`). Import
names spaces a file name declares (`LUTSpace.guess`); one file imported with a photo
open becomes its look, and removing the LUT in use drops the look (undoable). The look
pickers show each LUT on the photo (`LookPreviews`: small `keepsSource` renders that
never develop the photo again, only while a picker is on screen). Log spaces
(S-Log3 with S-Gamut3.Cine or S-Gamut3, V-Log, F-Log2, LogC3 EI800, LogC4, Canon
Log 3) are RAW-only inputs; they enter the LUT without the P3 fit, and an active
Log-input look develops the RAW scene-linear (`SourceOptions.sceneLinear`: boost 0,
the file's baseline exposure kept, gamut mapping off) so 18% grey lands on the curve's
middle grey and signed wide-gamut values reach the look. Built-in film and imported
LUTs are alternative looks (user, 2026-10-22); selecting either removes the other in
one undo step. Strength mixes the completed neutral/style SDR and HDR renditions in
linear light; RGB gain preserves both, so HDR-only controls never move the base.
Partial RAW Log/film looks also develop the Apple display endpoint, at preview/ROI
size, with both decoder allowances priced by `Recipe.needsLookBaseline` in export.
An export stages that endpoint once, in the canonical RAW cells, into an anonymous
float32 file (16 B/native pixel of free space, else `insufficientStorage`) before
the scene graph opens; bands read it back with the same pixels. The editor yields
while an export runs (`RecipeEditor.yieldToExport`: the shown and original frames
stay, its graph, detail and caches go) and develops the same variant again after.
Film renders taller than 1024 rows run in 256-row bands (same pixels, one band of
scatter workspace). PQ/HLG AVIF exports write from rows like HEIC.
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
4 GiB of remaining usable export budget, after the process reserve, and not
with 3 GiB.
61MP RAW opening, 1:1/pan and full-size Adaptive export, and the 60MP Sony HIF's
full-size HLG export have now succeeded on the physical iPhone 17 Pro. Use the
optimized `HyperDRiOS-Release` scheme for timing. Current measurements and remaining
110MP work are in `apps/apple/Packages/HyperDRRender/EXPORT_MEMORY.md`; real 110MP RAW
support is still unverified. The user resumed correctness-first optimization
on 2026-10-23. CPU remains the default HEVC transfer path; the opt-in Metal
experiment showed no HIF net benefit. The historical identical-recipe RAW
comparison differed by up to 9 decoded codes. This historical case is closed:
controlled request-shape reproduction and exact comparisons with the original
device artifacts established that CIRAWFilter's requested rectangle changes
its float development, and HEVC can amplify small input differences. Native
RAW reads use fixed global cells with a shared, zeroed RGBAf bitmap and validate the entire cell's
owned pixels before publication. Do not restore adaptive cell splitting or
generalize this case to universal pixel repeatability. Formal cap0/cap3
measurements are complete; retained-cell caching was deleted because it had
no consistent benefit. The final configuration without that cache produced
identical decoded pixels and compressed tiles in both Mac RAW scenarios, but
speed and memory showed no stable general improvement. It remains unverified
on a physical device or with a real 110MP RAW; see
`docs/reviews/raw-repeatability-film-2026-10-23/FINAL-NO-CACHE-2026-10-24.md`.
This optimization was developed in an isolated worktree. The iPad Studio UI
from main (9e927164) is now integrated, retaining the shared processing pipeline.
The iOS/iPadOS UI was redesigned on
2026-10-21 (library, editor, frame, export, LUT library; see the `HyperDRiOS` row). Then: P7-3e (saving to the photo library, after the user's Photos
Lab run using `prototypes/photos-lab/PhotosLab.xcodeproj`, merged into this
branch), the iOS background host and the hands-on checks
in `docs/design/user-acceptance.md`.
`.github/workflows/ci.yml` runs only for `main`; its sanitizer job runs the
C ABI lifecycle and package tests through `ctest`. Run the test scripts with
`python3.12`.
