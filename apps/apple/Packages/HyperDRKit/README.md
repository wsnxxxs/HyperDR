# Recipe exports (P7-3b)

`RecipeExportService` is the shared Mac/iPhone/iPad export operation. It accepts
`RecipeExportSnapshot`, the existing `ExportPlanRequest`, an optional frozen
Render `ColorLUT`, an optional preselected file URL, and a progress callback.
Keep the calling `Task` to cancel. A second operation on the same service fails
with `RecipeExportError.busy`.

Construct the service with `Engine`, a dedicated `RenderEngine`, an
`ExportStripeRendering` (the real Render implementation or a Fake), `SessionStore`
and `ExportTarget`. An optional prediction closure receives the Recipe model
selection and returns a prediction carrying its full provider identity. The
default resolves `research-cnn-v1` through its CoreML provider and uses Render's
RAW/SDR prediction entry. The service never converts a Recipe to EditOptions or
calls convert.

`RecipeExportSnapshot.modelSelection` reads the frozen Recipe's `hdr.model`;
callers need no loaded provider. The initializer's former `modelID` argument is
replaced by optional `expectedModelIdentity`, for an exact version requirement
when re-rendering history. Read that identity from
`ResolvedExportSnapshot.modelIdentity`, which also feeds ExportKey. The service
checks source and full identity on the prediction; an expected identity mismatch
fails with `missingModel`. Snapshot version 2 rejects re-rendering older snapshots
whose model name/identity semantics were ambiguous.

Capture `RecipeSourceRevision(session:)` when the source is opened. Reuse it at
export, rather than capturing a new revision after editing. Input source and
sensor sizes, domain, pair facts and resolved range belong in `ExportPlanRequest`.
`ExportPlanner.frameLayout(frame:choice:photo:)` computes the card around the
photo after the destination size limit; the UI draws the caption PNG at that
layout's caption rectangle and supplies Render's `FrameSnapshot`.

Use `SessionStore.saveRecipe(_:for:)` at completed edits and `recipe(for:)` on
reopen. Snapshots encode the caption's hash and geometry, not image bytes.
`SessionStore.resolveFrame(_:for:)` retains or loads its immutable PNG resource.
LUTs must be applied into the session with `LUTLibrary`; exports resolve the
retained content hash, so removing the library entry cannot invalidate history.
Missing local LUT/caption/model resources are explicit errors. The snapshot
schema can be reused for adjustment data without embedding external resources.

The service awaits AI, checks the source revision, consumes one GPU stripe at a
time into full owned float32 planes, packages them, waits for the package's own
reader, then verifies ImageIO/CI independently. Gain-map files are applied through
Core Image at the declared alternate headroom and an intermediate weight; no
assumption about ImageIO's default viewing headroom is used. Original package
JSON stays untouched inside `RecipeExportReport`; system evidence is separate.
The ordinary SDR HEIC path uses ImageIO without auxiliary data and is checked by
our HEIF decoder before system readback. Gain-map HEIC8 uses an explicit nonlinear
Display P3 RGBA8 CGImage and our gamma-1 quantized auxiliary gain plus complete ISO
metadata; it never asks ImageIO to generate gain or an SDR base. Native probe
finishes before ImageIO metadata/pixel checks. `RecipeExportReport.imageIO`
records the written gain parameters, with no fabricated package report.
HEIC10 and other encodings continue through `Engine.package`.

HEIC8 normally selects ImageIO. Its integer SDR base requires zero base headroom;
other pairs select our writer (`unsupportedCapability`) and are resplit as needed. If its separate CGImage/auxiliary handoff and
encoder estimate does not fit, admission tries our writer without changing
encoding, quality or dimensions (`memoryFallback`). Framed HEIC8 always uses our
writer (`frameGainProtection`): the manual ImageIO compression experiment leaked
up to five gain codes onto a non-block-aligned mat. Both reasons and the selected
writer are frozen in the resolved snapshot and report. The memory policy reserves
14 B/px for RGBA8/RGB-gain handoff copies plus 32 B/px codec workspace and 64 MiB
framework allowance beside the owner and source; it is a conservative policy,
not a measured iOS encoder limit.

The opt-in `writerComparisonMeasurement` test takes
`HYPERDR_HEIC8_BENCH_WRITER=imageIO|inHouse` and optional
`HYPERDR_HEIC8_BENCH_QUALITY` (default 90). Run each writer in a separate process
with `swift test --filter writerComparisonMeasurement`. It generates the same
2048×1536 synthetic planes and writes per-writer JSON and HEIC to
`/tmp/p7-heic8-lab`; metrics are SDR/sRGB 255 codes and HDR/PQ 1023 codes at 203-nit
SDR white. `writePeakBytes` is process `ru_maxrss` sampled before verification and
metrics, and includes the input owners and test runtime, not GPU total residency.

A verified file, frozen snapshot, evidence and SDR thumbnail are atomically
published as history before delivery. Nil destination returns that file for
fileExporter/share; stage shares with `SessionStore.stageExportForTransfer`.
Preselected Mac file authority is held throughout the operation. Delivery failure
or cancellation returns `deliveryError` with the verified version retained; a
render/encode/verification failure removes the unfinished version. Successful
file delivery writes `SavedMark` before the result is returned.

Render preparation scans the photo and then renders the output a second time;
this is not a streaming writer. Admission includes full source textures, CPU
planes, package copies, codec workspace and serial verification. Render stripes
may shrink from 256 to 128/64 rows; CPU/codec full-plane costs do not shrink.
Unmeasurable budgets use an explicit conservative 256 MiB limit. iOS uses 80% of
`os_proc_available_memory`, and Metal's recommended working set is checked
separately. The allocation estimates are conservative policies awaiting P7-3d
footprint calibration; this does not promise 61 MP iPhone export. Transparent
raster RGB retains the old decoder's black SDR background convention
(`modules/codec/src/internal/cicp.hpp`).

`PhotoLibrarySaver` is an explicit disabled entry (`photos_not_verified`) and a
Fake seam. It performs no Photos transaction or permission request until Photos
Lab establishes the modes that may be enabled. Background GPU hosting and
incremental writers are later batches.

The Mac and iOS apps both export through this service; the old JobRunner,
preview service, EditOptions and their CLI parity check are gone. Recipe history
uses `recipeSnapshot` and `resolvedSnapshot`; the legacy options field is empty
for new exports and is never used to restore a Recipe.

The real RenderEngine conformance is integrated from `510e39cc`. Service tests
exercise all eight encodings through the real Recipe graph and both readers,
including a caption/shadow card through gain-map, SDR and PQ paths; a transparent
PNG against linear-black compositing; and an authored RGB/nonzero-offset pair
through preservation, writer resplit, a narrower destination and frame neutrality.
Kit records Render's explicit output-ceiling report even when Render folds it
into the edited authored pair before its capability scan needs a further resplit.

`python3.12 scripts/test.py ios` checks the package artifact for macOS arm64,
iOS arm64 and iOS simulator arm64 archives/headers, plus the adjacent
`engine-source.sha256` content fingerprint. Missing, incomplete or stale slices
trigger `build_xcframework.sh --platforms all` before either app build. The Mac
suite uses the same freshness check for its macOS slice.
Source SHA-256 already runs off the caller in a detached task, with chunk-level
cancellation; `SessionStore.open` waits for it to establish content identity and
history/session reuse. A host may start that task alongside photo decoding and
await the same task when preparing export, rather than serializing both opens.


## Incremental export integration (P7-3d-K)

`ExportRowRendering.prepareRows` accepts a lazy `HyperDRRender.ExportSource` and
frozen Recipe/LUT/prediction/request. It returns `ExportRowSource`, whose report is
fixed and whose synchronous `read(y:count:)` may be replayed. A renderer may opt
into this separately from `ExportStripeRendering`; the service also accepts an
explicit `rowRenderer` injection. `RenderEngine` implements the protocol through
`prepareExportRows`; `PreparedExportRows` supplies the frozen report and synchronous
ROI reader on its private renderer executor. A renderer without this protocol
keeps the whole-plane path. Setting
`ExportPlanRequest.allowsRowInput=false` provides that same parity baseline.

Native JPEG/TIFF/ISO JPEG/HEIC writers pull rows through `PackageRowBridge`, not a
canvas owner or spool. Each callback validates and copies one stripe into the
engine's borrowed buffers and returns before the next one. The source scope and
revision stay frozen until verification/publication. A bounded <=256px linear
thumbnail accumulator accepts each source row once, so replays cannot bias it.
Rendering and encoding overlap; encoding progress stays an active stage instead
of claiming completion on an intermediate scan pass. `usesRowInput` is recorded
in both resolved snapshot and report.

ImageIO manual HEIC8/SDR HEIC and AVIF keep whole-plane writing. HEIC8 selected as
a memory fallback to our writer uses the row path. Admission compares writer plus
format capabilities; analysis/prediction use the lazy source's fixed analysis
image, and a full source is loaded only when the final plan needs whole planes.

The row model prices fixed analysis, decoder/RAW caches, source ROI and active
Render graph, 56 CPU+32 GPU bytes per RGB-gain readback pixel, package input band,
and HEIC's independent 512-row RGB Float slab plus a fixed VT queue reserve. HEIC also reserves compressed tiles
plus assembly bytes (two copies, estimated at 3 B/pixel or 5 for adaptive10, plus
8 MiB). These are reserve policies, not measured encoder limits. Preparation's
256-row scan and the encoding reader are successive phases; 256/128/64 input
choices reduce the latter, not the fixed scan or HEIC slab. Native verification
of these row formats now uses scanlines or a matching HEIC 512×512 tile pair, with an 8 MiB codec reserve plus row/tile workspace. The
estimate exposes `nativeVerify` and `systemVerify`; `verify` is their maximum,
not their sum. Native row output uses the reduced ImageIO reader described below;
AVIF and ImageIO writing retain their whole-plane verification estimates. This
does not claim constant memory for all formats or guaranteed 61MP iPhone admission.

Opt-in bridge/writer measurement: run `streamingHeightMemoryMeasurement` in fresh
processes with `HYPERDR_STREAM_HEIGHT=1024`, then `4096`. At 2048 pixels wide and
64 rows, process `ru_maxrss` was 72,744,960 B (69.38 MiB) versus 72,581,120 B
(69.22 MiB). It includes the real Kit row bridge, bounded thumbnail and native
incremental TIFF, with a procedural Fake row source and verify=false. It excludes
real system source/Render/verification residency; JSON is in
`/tmp/p7-stream-memory/`. The separate six-format test compares whole versus rows
with identical decoded pixels, including JPEG's intentionally different entropy
coding, and confirms multi-band gain analysis/encoding replay.

Real source/Render measurement (P7-3d-K): `realStreamingHeightMemoryMeasurement`
uses a generated system JPEG source, the lazy analysis source, the real 256-row
Render preparation scan, replayable 64-row ROI reads, the Kit bridge/thumbnail,
and native incremental SDR TIFF with `verify=true`, followed by the same
`ExportVerification.system` check used by the service. Generate each input in a
separate process by setting `HYPERDR_STREAM_REAL_HEIGHT=1024` (then `4096`) and
`HYPERDR_STREAM_REAL_GENERATE_ONLY=1`; run the same filtered test in a new process
without the generate-only variable. This excludes the generator's full-size
CGContext from the export process high-water mark. Files are synthetic and removed
after measurement; JSON remains in `/tmp/p7-stream-real-memory/`.

| Process high-water mark (`ru_maxrss`, bytes) | 2048×1024 | 2048×4096 |
|---|---:|---:|
| Before engine/source | 43,745,280 | 43,761,664 |
| After system source/analysis | 90,980,352 | 90,931,200 |
| After Render preparation | 92,848,128 | 92,749,824 |
| After row writing, native bounded verification and thumbnail | 102,563,840 | 103,038,976 |
| After independent ImageIO check | 103,022,592 | 103,399,424 |

These numbers were remeasured after integrating `cfb84a56` and rebuilding all
three engine slices. At fixed width, the complete source/Render/package/native
verification/system readback path stayed at 98.25/98.61 MiB across four times the
height. Native-verification completion was 97.81/98.27 MiB. Unlike the earlier
measurement, this invokes package's bounded write-time verifier, not the general
full-image `Engine.probe` API after an unverified write. ImageIO here checks a
256-pixel SDR thumbnail and metadata; this sample shows no full-image growth.
Its decoder and auxiliary data caches remain an explicit full-image admission
reservation for other formats, particularly gain-map/BT.2100 readback.

The measurement checks an arbitrary band twice for exact replay before packaging.
It is a macOS synthetic SDR JPEG/TIFF sample, not an admission guarantee for RAW,
dual inputs or iOS; the decoder/HEIC reserves remain. The real service's six-format
test also compares decoded pixels against whole-plane output, including a
multi-band framed HEIC pair. Service tests retain Fake injection for deterministic
failure paths.

## iOS export admission diagnostics and reduced system readback

`RecipeExportServicing.lastMemoryDiagnostic` is available after a failed export,
including process rejection by the planner before rendering. It records process
versus GPU, planning versus running, required/available bytes, and computed
required/available/shortfall MiB. It resets on the next accepted operation. The
same numeric summary is logged publicly in `com.hyperdr.HyperDR` / `Export`, with
no photo paths. Existing `RecipeExportError` cases remain unchanged. iOS currently
drops `.memoryExceeded` details; its host can await the diagnostic in the failure
handler and localize the check/phase labels when showing these MiB fields.
Metal's zero recommendation is unknown (observed on Simulator), so GPU admission
is skipped in that case; process admission is always retained. Nonzero device
recommendations remain enforced.

Native row output now obtains auxiliary **metadata** from ImageIO's file-contents
properties, without copying the full decoded auxiliary-data dictionary. It asks
`CGImageSourceCreateImageAtIndex` for 1/8 decoder subsampling, SDR or HDR as
appropriate, and float output; JPEG MCU rounding is allowed. Unexpected full-size
fallback is refused. The decoded image is at most the even-rounded 1/8 dimensions
and is sampled into a <=64px Float buffer. These are public ImageIO APIs available
before iOS 26; the CI-specific subsample API requires iOS 27 and is not used.
Our retained readback buffers scale with 1/64 of output area, not full area; this
is not a promise that Apple's private decoder caches are allocator-bounded.

The independent system reader still checks original dimensions, upright primary
orientation, bit depth, gain auxiliary presence/absence, reduced HDR/SDR decode,
finite pixels and finite content headroom, and reports the profile name. For row
output, `verifiedHeadroomStops` now contains the decoded content headroom rather
than claiming two separately applied gain-map headrooms. It does not compare
full-resolution system pixels or manually reconstruct the pair at maximum and
intermediate headrooms. Native row/tile validation still checks every full-size
pixel, gain metadata, reconstruction, orientation and E5 before this readback.
AVIF and ImageIO manual writing keep their existing full-plane checks/estimates.

Offline RAW example: 9504×6336, no size limit, no frame/LUT/prediction overhead,
rawEDR, native row input, Adaptive HEIC10 / ISO JPEG8. Values are MiB, successive
stage peaks (not summed), with the same estimates on iOS. Use
`HYPERDR_MEMORY_ESTIMATES=1` and test `fullSizeRAWMemoryEstimates` to reproduce.
This does not substitute host RAM for a device's measured remaining budget.

| Stage, 256 rows | HEIC before | HEIC after | ISO JPEG before | ISO JPEG after |
|---|---:|---:|---:|---:|
| Decode/resident | 961.5 | 961.5 | 961.5 | 961.5 |
| Render / composite | 1147.7 | 1147.7 | 1147.7 | 1147.7 |
| Packaging / encode | 2175.5 | 2077.6 | 1407.9 | 1407.9 |
| Native verification | 1165.7 | 1165.7 | 1156.9 | 1156.9 |
| System verification | 3444.8 | 1201.6 | 3444.8 | 1192.8 |
| Peak | 3444.8 | 2077.6 | 3444.8 | 1407.9 |

| Rows | Old peak, both | New HEIC peak | New ISO JPEG peak |
|---|---:|---:|---:|
| 256 | 3444.8 | 2077.6 | 1407.9 |
| 128 | 3352.0 | 1854.8 | 1185.1 |
| 64 | 3305.6 | 1743.4 | 1147.7 |

RAW retains a 918.8 MiB decoder/development reserve. For HEIC the writer actually
owns one RGB Float slab (12 B/px), not a full-width 40 B/px YUV/Float canvas; the
model now prices that slab plus 32 MiB for the bounded four-picture VT queue and
framework workspace. Compressed tiles plus the assembled container still reserve
two copies at 5 B/px for HEIC10 (~574.3 MiB). Those writer allocations, and the
fixed 256-row Render scan for JPEG, dominate after removing the full system map.
The QA report proves Simulator's GPU zero-limit rejection; it contains no numeric
process/GPU budget at the old phone failure, so its exact failed check cannot be
retrospectively identified. The GPU estimate is 383.9 MiB at 256 rows and
309.6 MiB at 128/64 rows (the fixed preparation scan remains); the phone's actual
Metal recommendation was not captured. The new public diagnostic resolves this
on retest.

HLG pull observation: 512-row HEIC slabs reuse data across horizontal tiles.
256/128/64-row package bands all divide 512, so smaller bands add callbacks but
not an extra per-tile Render pass. Gain extrema/codebook scan and encode each
traverse the image. For 4032×3024 HLG at 256 rows this is 12 reads per traversal,
24 package callbacks plus Render's separate 256-row preparation scan. The encoding
stage includes all pull rendering, VT encoding and native verification; 13.9 s
cannot be attributed to read latency from that aggregate timer alone.

`increased-memory-limit`: Apple's [entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit)
only promises additional memory on supported models and requires checking
`os_proc_available_memory`. There is a [first-person Personal Team/Xcode report](https://github.com/SideStore/SideStore/issues/1616)
that the entitlement is retained and increases available memory with a free team;
so paid membership is not a necessary assumption for this entitlement. It has not
been signing-tested in this task. If tried later, verify the generated profile,
signed entitlement and device budget; do not assume it bypasses process/GPU
admission. No entitlement was added here.
