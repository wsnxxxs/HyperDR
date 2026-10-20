# Recipe exports (P7-3b)

`RecipeExportService` is the shared Mac/iPhone/iPad export operation. It accepts
`RecipeExportSnapshot`, the existing `ExportPlanRequest`, an optional frozen
Render `ColorLUT`, an optional preselected file URL, and a progress callback.
Keep the calling `Task` to cancel. A second operation on the same service fails
with `RecipeExportError.busy`.

Construct the service with `Engine`, a dedicated `RenderEngine`, an
`ExportStripeRendering` (the real Render implementation or a Fake), `SessionStore`
and `ExportTarget`. An optional prediction closure can reuse a CoreML provider;
the default checks the frozen model identity and uses Render's RAW/SDR prediction
entry. The service never converts a Recipe to EditOptions or calls convert.

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
our HEIF decoder before system readback. Other encodings use `Engine.package`.

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

The old JobRunner/preview/EditOptions files remain for the Mac caller's pending
switch. Recipe history uses `recipeSnapshot` and `resolvedSnapshot`; the legacy
options field is empty for new exports and is never used to restore a Recipe.

The real RenderEngine conformance is integrated from `510e39cc`. Service tests
exercise all eight encodings through the real Recipe graph and both readers,
including a caption/shadow card through gain-map, SDR and PQ paths; a transparent
PNG against linear-black compositing; and an authored RGB/nonzero-offset pair
through preservation, writer resplit, a narrower destination and frame neutrality.
Kit records the planner's output-ceiling constraint even when Render folds it
into the edited authored pair before its capability scan needs a further resplit.
