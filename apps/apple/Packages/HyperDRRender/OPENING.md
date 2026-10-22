## Platform compatibility

RAW 9 requires iOS/iPadOS 27 or macOS 27 and per-file support. The app's minimum
OS remains 26. `preferredRAWDecoder` checks `supportedDecoderVersions` and selects
its existing entries by raw value, avoiding references to `.version9` or
`.version9DNG` symbols that can fail to load on older systems. New photos on 26
keep Apple's available default; restoring an unavailable recorded decoder fails
explicitly. See Apple's DTS explanation: https://developer.apple.com/forums/thread/843445

# Opening feedback and RAW preview reuse

## UI contract (shared RecipeEditor)

All properties below are read-only to views, MainActor-isolated and observed by
Observation. No AppKit/UIKit enters the shared editor or Render package.

- `isOpening` remains the source-open state. It becomes false when the source is
  installed; the first edited frame can still be pending.
- `openingPhase: EditorOpeningStage?` covers that remaining interval as well:
  `reading` → `loadingDecoder` (RAW graph setup) → `developing` (materialization)
  → `preparingPreview` (fixed analysis/source report) → `rendering` (first frame).
  A phase is coarse work attribution, not a percentage. Apple's decoder can load
  its system model during setup or materialization; there is no separate model-
  loaded callback. Do not label every `loadingDecoder` as a cold Core ML load.
  Stale callbacks are rejected by generation and phase order.
- `placeholder: CGImage?` holds an already decoded, oriented, 8-bit sRGB embedded
  thumbnail. `placeholderURL` owns it; `placeholderID` is a unique presentation
  token, **not** `EditorSource.id`. The editor's source can still be the old photo
  while the new placeholder is available. The backend rejects stale thumbnail
  results, including a newer request for the same URL.
- `placeholderPixelSize: HyperDRRender.PixelSize?` gives the oriented full-photo
  aspect ratio, before source opening completes, and is reconciled with
  `EditorSource.pixelSize` once known. Fit the placeholder to this ratio and crop
  its edges as needed: an embedded camera JPEG can have a slightly different
  crop (the Sony thumbnail here is 1024×684 for a 9504×6336 source).
- The placeholder is fetched before waiting for an old cancelled decode to unwind.
  It never becomes a RenderSource or enters adjustments, AI, capture or export.
  Missing thumbnails return nil. There is no synthetic full-image fallback.
- Phase/placeholder clear on the first successful frame, failed open, cancelled
  open, failed first frame or close; a new request immediately clears the old
  placeholder. The UI can retain its outgoing image for a 0.25 s fade.
- A failed first frame still leaves `renderFailure != nil` and does **not** move
  `frameSource` to the new source. The previous frame can remain visible. This
  existing error contract is preserved and tested.

`EmbeddedPreview` reads RAW and HEIF only, using ImageIO with
`kCGImageSourceCreateThumbnailFromImageIfAbsent=false`, orientation and a 1024 px
bound (hard maximum 2048). HEIF additionally requires a listed thumbnail item;
some ordinary raster readers synthesize thumbnails even with IfAbsent=false.
The bounded image is decoded into an owned SDR bitmap on a detached task, with
cancellation forwarded. Default output storage is at most 4 MiB, excluding
ImageIO's internal workspace; this is not an iPhone footprint measurement.
Photo-library fetching and the imported-file copy precede this API and continue
to use EditingSession's existing loading state.

## Original-preview failure and retry

`originalFailure: String?` is a separate observed MainActor property, containing
an internal error description for the original preview (never a cancellation).
It does not replace `renderFailure`, which still describes the edited preview.
An original frame and its detail are removed synchronously whenever source or RAW
development changes, including during a drag. Consumers must handle nil original
pixels as unavailable; they must not label the edited frame as Original. Same-
development resize failures can retain the valid smaller original frame.

A failed original request is not retried for unrelated tone/HDR edits. A changed
original request retries automatically; a drag waits until release. Late cancelled
results cannot publish. Success, a new development, successful photo open or close
clears the original error. `sourceChanged` also records original-branch file changes.

`retryRendering()` retries both previews from the current recipe, without changing
undo history, source, render dimensions or AI defaults. No effect while opening,
without a source, or after `sourceChanged` (that file must be reopened). The edited
error remains until successful render; the original error clears as its retry starts.
All calls and Observation mutations use MainActor. No UI/localized text is added.

## AI state

No current model key (HDR off, another HDR source, bypassed HDR, opening/closing
another photo) cancels the obsolete prediction and sets `.idle`; a published
`.unavailable` stays unavailable. Development changes cancel an obsolete key;
while dragging, the current model stays pending and starts after the drag ends.
Predicted entries remain cached. Returning to a needed key restores `.ready`,
`.failed`, or starts `.computing`. Late cancelled completions cannot change the
current state. A renderer-originated CancellationError clears its completed task
and key instead of leaving settle/state observers attached to a finished task.
A failed successor open resumes only the prior photo's needed prediction.

## Low-risk reuse

The initial source bound is square; the fitted canvas bound has the photo's aspect
ratio. These SourceOptions differ even when they round to the same RAW raster,
which previously reopened and redeveloped the whole preview before the first frame.
`RenderSource.reusesRAWPreview(options:)` compares every development setting and
calculates the exact resulting raster from native dimensions and developed extent.
Only identical rasters are reused, with file-revision validation. Different sizes,
development settings and ROI sources are excluded. There is no change to decoder,
precision, kernels, sampling dimensions, analysis policy or export.

## Mac measurements before shared-graph analysis — 2026-10-22

macOS 27.0.1, Apple M6, DSC01468.ARW, 9504×6336, 1280-long-edge preview.
Optimized Swift package test build (`-c release -Xswiftc -DDEBUG`; DEBUG retains
the existing fake-renderer test symbols). These are local Mac runs under concurrent
development, not iPhone timings or statistically stable speed claims. The system
RAW model cache was already warm; the previously measured 4.7 s cold setup was not
reproduced in these runs. The two runs use fresh RenderSession/RenderEngine objects.

| Stage | RAW 9 run 1 / 2 | RAW 8 run 1 / 2 |
|---|---:|---:|
| Embedded SDR placeholder | 0.227 / 0.025 s | 0.114 / 0.032 s |
| Decoder selection | 0.088 / 0.060 s | explicit 8, <0.001 s |
| RAW filter/graph setup inside load | 0.158 / 0.090 s | 0.102 / 0.085 s |
| Native ROI preview materialization | 3.157 / 3.023 s | 1.251 / 1.882 s |
| Fixed 1024 analysis/source report | 3.995 / 3.965 s | 1.504 / 1.588 s |
| Total source open | 7.398 / 7.140 s | 2.858 / 3.555 s |
| First frame after open, with reuse | 0.006 / 0.010 s | 0.010 / 0.010 s |
| Optional app AI highlight prediction | 0.910 / 0.067 s | 0.921 / 0.044 s |
| First AI frame after prediction | 0.008 / 0.005 s | 0.012 / 0.006 s |

Before reuse, RAW 9's first frame after open spent another 3.697 / 5.012 s
redeveloping the same raster. After reuse, both RAW 8 and RAW 9 matched an explicit
reopen reference **exactly** in Float base and gain planes (max error 0 in all four
comparisons). The fixture regression checks the same property. This validates
these cases; it does not resolve the pre-existing universal RAW repeatability issue.

Before the shared-graph change below, the 7 s RAW 9 source-open time was dominated by native ROI development and fixed
analysis, not the warm decoder setup or optional highlight inference. No startup
prewarm or smaller initial preview tier is enabled. Prewarming would retain extra
system/decoder/model workspace with no measured iPhone benefit; it cannot remove
the native pixel work. Current previews area-sample bounded native ROIs over the
whole sensor: a smaller output tier still visits those native pixels, so reducing
its dimensions alone does not imply less RAW development. Replacing fixed analysis
with another preview, or introducing a smaller provisional tier, needs separate
pixel/automatic-value and device-memory validation. Current final pixels and preview tier are retained.

Reproduce explicitly (normal tests do not depend on local photos):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
HYPERDR_OPEN_TIMINGS=1 HYPERDR_OPEN_BENCHMARK_RAW=/path/to/photo.ARW \
swift test -c release -Xswiftc -DDEBUG \
  --package-path apps/apple/Packages/HyperDREditorCore \
  --scratch-path build-apple/swift-editor-core --filter rawOpeningBenchmark
# Add HYPERDR_OPEN_DECODER=8 for the legacy comparison.
```

Evidence: ignored `build/loading-backend/open-9.txt` (before reuse),
`open-9-reuse.txt` and `open-8-reuse.txt`. No RAW 9 loading or memory claim for a
physical iPhone/iPad is made by these measurements.


## Fixed analysis investigation and shared RAW graph — 2026-10-22

`sourceReport` needs the unedited source headroom plus cheap source defaults and
capabilities. Headroom calls `analysis`, which first obtains `fixedAnalysisSource`.
Previously that reopened `CIRAWFilter`, with the same recorded decoder and every
RAW setting, and materialized a second 1024-long-side source. `filter.scaleFactor`
is always **1**, draft mode is off: the 1024 bound is an output area-sampling grid,
not a reduced RAW decode. For the 61MP Sony, both the 1280×853 preview and the
1024×683 fixed source make 39 bounded native ROI renders and request 60,597,720
native output pixels including overlap (excluding the decoder's internal input halos). Every ROI still traverses the RAW 9 system
pipeline, including its system demosaic/denoise; the optional HyperDR highlight
Core ML prediction is **not** run by sourceReport. Apple's API does not expose
separate demosaic/model/cache timing, so the native-render time cannot be split
further reliably.

After this materialization, analysis makes a fixed 768×512 grid: graphCells
(point/look transforms, luminance/captured/analytic peaks and masks), box blurs,
weights, coefficients, final analytic gain and a peak reduction. The resulting
SpatialAnalysis is cached. On this Mac those GPU operations took 0.055–0.071 s;
the repeated native development accounts for almost all the earlier 4 s report.

`RenderEngine.load(..., preparingAnalysis: true)` now retains its **one temporary
native RAW graph** long enough to materialize both independent output grids. Both
use the existing `rasterizeRAWPreview` without changing any ROI coordinates,
halos, integration order, precision or working/output color spaces. No preview
pixels are used as analysis input. `OpenedSource.rawVariant` centralizes the exact
existing bound/rounding policy and informational scale metadata; resolution never
changes a native filter parameter. Once load returns, neither RenderSource retains
the native graph. Only the existing preview/fixed textures stay resident.

RenderSession opts in on open and subsequent development reloads. The default
load API and export entry point retain their behavior. Export still obtains the
same canonical 1024 source independently. Cached loads can prepare missing
analysis through the ordinary fixed-analysis path. `SourceLoadPhase.preparingAnalysis`
maps to the existing editor `openingPhase = .preparingPreview`; no UI stage or
localized text is added. OPEN_TIMING's development duration now includes preparation;
the OPEN_PHASE boundaries separate it from preview development.

Same Mac/61MP photo as above, optimized package tests in separate fresh processes,
warm system-model state; later runs with less concurrent development. Times exclude
engine construction, thumbnail, decoder selection and optional app AI inference.
RSS is the process high-water resident set from getrusage, including engine setup;
it is not a measurement of total device GPU/system memory or iPhone memory.

| Stage | RAW 9 old / shared | RAW 8 old / shared |
|---|---:|---:|
| Preview load, including filter setup | 2.624 / 2.839 s | 1.073 / 1.090 s |
| Fixed source development | 3.167 / 0.416 s | 1.067 / 0.824 s |
| Spatial GPU analysis | 0.059 / 0.062 s | 0.055 / 0.059 s |
| Total development + spatial analysis | 5.850 / 3.317 s | 2.195 / 1.973 s |
| Peak process RSS | 273.7 / 274.0 MiB | 341.0 / 340.5 MiB |

The improvement is consistent with reuse of Apple's internal decoded/intermediate
state in one graph; the API does not reveal which internal cache is responsible.
It does not remove the second independent ROI integration. There is no concurrent
second decoder/context or persistent native cache. No export memory estimate is
changed; iPhone performance and footprint still need device measurement.

Equivalence: five complete Float texture SHA-256 digests (preview, fixed source,
spatial cells, masks and expansion) match bit for bit in the baseline/shared fresh
process runs for both RAW 8 and RAW 9. Fixture regressions additionally compare
preview, canonical reopened fixed source, export fixed source, all spatial maps,
peaks, sourceHeadroom and final edited base/gain planes, with Apple-boost and scene-linear developments. Sony and
Leica fixtures use their supported legacy decoder 7; the Canon DNG uses 8.dng and
9.dng. Unsupported decoder cases skip. This is evidence for these cases, not a
claim to resolve the earlier universal RAW repeatability issue.

Rejected shortcut: downsampling the already materialized 1280 preview to 1024
changes the area footprints and is not equivalent. RAW 9 max/mean linear RGB
error was 0.142691 / 0.000831 (RAW 8: 0.112686 / 0.000841); about 2.098 million
channels differed. It is not installed. Parallel development is also unnecessary
for this change: sharing one serial graph yielded the measured benefit without
introducing a second native decoder working set.

Reproduce the detailed phases and rejected shortcut with the opt-in XCTest probe:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
HYPERDR_RAW_ANALYSIS_PROBE=/path/to/photo.ARW HYPERDR_RAW_ANALYSIS_DECODER=9 \
swift test -c release --package-path apps/apple/Packages/HyperDRRender \
  --filter RAWAnalysisProbeTests
# Add HYPERDR_RAW_ANALYSIS_MODE=baseline or =shared for isolated process
# timing/RSS and five texture digests. Use decoder 8 for the legacy comparison.
```

Evidence: ignored `build/loading-backend/analysis-9.txt`, `analysis-8.txt` and
`analysis-{8,9}-{baseline,shared}.txt`. Normal tests never require personal photos.


## Ricoh GR IV DNG on the Simulator — 2026-10-22

Local input: `1792403618000_R0000312.DNG` (6192×4128 native, 4128×6192 oriented).
The QA Simulator is iOS 27.0 build 24A434, device UUID
`39BACC04-9365-46BD-9B29-591F98D762A5`, named HyperDR iPhone 17 Pro QA;
Metal reports Apple iOS simulator GPU. The Mac is macOS 27.0.1 build 26A434, M6.
The physical iPhone is not measured here, so this does not establish a general
Simulator-only or ANE limitation.

A standalone Core Image probe (outside HyperDR, no Render package) confirms:

| Input / decoder | QA Simulator | Mac |
|---|---|---|
| Ricoh / 9.dng | `outputImage == nil` | Native ROI renders, alpha 1 |
| Ricoh / 8.dng | 64×516 and 4096×516 native ROIs render, alpha 1 | Existing working default |
| Sony A7R V / 9 | Native ROI renders, alpha ~1 | Existing working decoder |

For Ricoh/9 the system logs `V8 Noise Reduction requested, but no ISO Dictionary
present.` This also occurs with only the decoder changed on the default filter,
and with luminance NR zero. It fails while obtaining `CIRAWFilter.outputImage`,
**before constructing any CIContext or our native ROI/stripe destination**. Thus
RGBAf versus RGBAh, extended sRGB, CPU versus Metal context and row bounds cannot
fix this reproduced failure; corresponding probe modes never reach those steps.
The app reproduced the same system message. The earlier UI report's
`CVPixelBufferCreate returned err -6680` was not reproduced verbatim in this run;
Apple's CVReturn.h identifies -6680 as `kCVReturnInvalidPixelFormat`, not out of
memory. Both observations point upstream of our pixel-buffer/texture handling,
but Apple's closed implementation does not expose the exact missing camera/model
resource. A global lack of RAW9 support in the Simulator is ruled out by Sony/9.
Runtime/camera support differences remain possible; physical-device verification
is still required.

A conservative fallback is implemented in **RenderSession's new-photo open only**:
if the automatically selected known generation 9 throws `RenderError.cannotDecodeSource`,
query the current file's actual valid, nonempty, supported system default and
retry it once, explicitly setting that version. New options/source/model identity,
source defaults/capabilities, new recipe, original, AI and export capture then all
use the successful version. A nil/system-default identity is never substituted
for the recorded successful decoder. No global camera blacklist is kept.

Restoring any recipe (including a legacy nil decoder), export, reload/development,
cancellation, source changes, allocation failures and unrelated GPU errors never
trigger this downgrade. A fallback failure propagates without another retry.
No string matching or broad catch-all retry is used. `defaultRAWDecoder` excludes
.none/empty defaults just like preferredRAWDecoder excludes non-RAW pseudo-versions.

`EditorSource.rawDecoderFallback: RAWDecoderFallback?` provides `{ requested, used }`
for hosts that explain the automatic choice. The effective recipe version is the
source's `rawDecoderVersion`; fallback metadata is an opening notice, not recipe
processing state. RecipeEditor's observed `source` publishes it on MainActor.
No view or localized strings are added. `HYPERDR_OPEN_TIMINGS=1` prints the fallback
when enabled. Existing opening phases remain monotonic through a retry.

Fault-injection regression tests use the fetched Canon fixture, with 9.dng
preferred and 8.dng default (skip when unsupported). They cover new-photo fallback,
actual version in encoded recipe/export/original, first-render and look-preview
reuse without reload, subsequent normal open returning to 9, strict restored 9
and legacy recipes, cancellation/allocation/GPU/file/invalid-size failures, and
only one default retry. Ordinary JPEG/HEIC/PNG tests also assert a nil default RAW
version.

After installing the rebuilt app, QA Simulator Ricoh open logs:
`OPEN_RAW_DECODER_FALLBACK requested=9.dng used=8.dng`, then successful preview/fixed
materialization and source report with `decoder=8.dng`. The canvas displays the
photo, with no loading/failure overlay. Source load + fixed preparation was 1.721 s
and spatial report 0.067 s in that debug run, not an optimized iPhone benchmark.
Evidence (ignored): `build/raw-simulator/probe.swift`, `probe-{sim,mac}`, matrix
`*.log`, `app-before.log`, `app-after.log` and `app-after.png`.
