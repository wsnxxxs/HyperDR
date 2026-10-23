# Export admission after tiled Render

The row path follows HyperDRRender/EXPORT_MEMORY.md. Full-plane writers (AVIF,
ImageIO) still price their actual whole-plane owners and may be refused.
All figures below are estimates, not measured iPhone footprints. The RAW 9 Mac
measurements (2026-10-22) fit the existing row allowance. Whole-plane RAW fallback
now reserves the same 24N + 512 MiB decoder allowance beside its full source texture,
rather than 16N alone; see Render's measurement table. Formal cap0/cap3 device
measurements are complete, and retained-cell caching was deleted for lack of a
consistent benefit. The final configuration without the cache produced identical
decoded pixels and compressed tiles in both Mac RAW scenarios, but speed and
memory showed no stable general improvement. It remains unverified on a physical
device or with a real 110MP RAW; see
`docs/reviews/raw-repeatability-film-2026-10-23/FINAL-NO-CACHE-2026-10-24.md`.

For native area N, canvas width W and callback height R:

- Decoder/work allowance D = 24N + 512 MiB, once. This is empirical, from the
  Render measurements, not a universal Apple decoder cap. Sensor area is used
  if larger than the developed raster. Reducing the output does not shrink N.
  Partial RAW scene looks reserve a second 24N decoder allowance; the fixed
  512 MiB work allowance is still charged once. Single-cell RAW scratch is
  covered there; no completed-cell cache or separate cache surcharge remains.
- Retained LUT/caption/specification resources are added in every stage.
  Dual input additionally reserves 16 B/native pixel for its auxiliary image
  until exact auxiliary dimensions are available. This is independent of the
  base decoder. Existing editor memory is already excluded from the physical
  device's `os_proc_available_memory()` result; never credit it to export or
  count it twice. Independent decoder caches are not assumed to overlap.
- Returned CPU rows B = 4(3 + gainChannels)WR. The native callback destination
  also owns B simultaneously, so the row stage charges 2B. Unknown gain channel
  counts reserve RGB. RGB packing adds 24 MiB over the mono work allowance
  (12 B × Render's maximum 4096 × 512 output tile).
- The fixed work allowance covers bounded graphs/analysis and mono packing
  scratch; no full-width source band or area-scaled Render graph remains.
  GPU admission uses Render's maximum source tile/read rows and the actual
  device's `maximumTextureDimension`, rather than logical canvas dimensions.
- HEIC encoding adds a 12W × min(512,H) float slab, 32 MiB codec allowance and
  a fixed **16 MiB** stored-sample workspace C. Completed compressed samples
  are spooled to an anonymous file; C covers callback input/repacking, one stored
  read and allocator/stdio overlap, not a whole compressed sequence. Each tile
  is bounded to 4 MiB, and offset/length tables to 4096 tiles. C does not scale
  with canvas area, quality or output-file size. Both full-plane and row package
  paths stream the container into the staged file. Items and <=256 KiB writes
  borrow spans. Assembly retains C but releases the float slab and VT pictures;
  its separate 32 MiB allowance covers bounded metadata/box construction
  (Exif/XMP are individually limited to 4 MiB) and file buffering.
  JPEG adds 32W codec workspace. Stage peaks are compared, not summed.
- Active film adds 48 × min(photoWidth,4096) × min(photoHeight,516) bytes for
  its three RGBA float32 textures, at most **96.75 MiB**, to rendering and
  encoding. HEIC assembly and verification do not retain this workspace.
  Zero-strength or disabled film adds none. GPU admission prices the same
  bounded film workspace independently of the process-memory estimate.
- Native/system verification keeps the same decoder/work allowance plus bounded
  row/tile and thumbnail workspace. `maxAdmissibleLongEdge` uses this same
  estimator, including the invariant native decoder floor. It binary-searches
  only scalar memory estimates (at most about 14 candidates for a 12800 edge),
  without constructing a full plan for each pixel of the rejected long edge.

## RAW budget table

Calculated from the final `ExportMemoryEstimate.estimateRows` integer-byte
formulas and its fixed 16 MiB spool workspace; these
are admission estimates, not new benchmark or physical-device results. All
figures are MiB (2^20 bytes), rounded to one decimal. The scope is native row
input with the in-house writer, full original size, one RAW development, RGB
gain reservation (even though separated RAW normally uses mono), no active film,
frame, LUT, caption or model-prediction overhead. Quality is q95; the two formats
are Adaptive Main10 and ISO JPEG8. The spool reservation is quality-independent.
Values can be reproduced with
`HYPERDR_MEMORY_ESTIMATES=1 swift test --filter fullSizeRAWMemoryEstimates`.
61MP means 9504×6336 (60.22MP); 110MP means 12800×8600 (110.08MP).

For these rows, RGB packing scratch S = 12 × 4096 × 512 = 24 MiB,
returned B = 24WR, and HEIC float slab L = 12W × min(512,H). Therefore:

- Decode = D; render/composite = D + S.
- HEIC encode = D + S + 2B + L + 32 MiB + C.
- HEIC assembly = D + S + 2B + 32 MiB + C, with C = 16 MiB.
- ISO JPEG encode/assembly = D + S + 2B + 32W bytes.

The native/system verification estimates remain bounded and below encoding in
these cases. Partial RAW scene looks and active film add the reservations above;
they are outside this table's single-development, film-disabled scope.
The final column separates assembly / peak where they differ; Adaptive now
peaks during encoding, while its float slab and VT workspace are still alive.

| Native | Format | Rows | D | Returned B | Encode | Assembly / peak |
|---|---|---:|---:|---:|---:|---:|
| 61MP | Adaptive | 256 | 1890.3 | 55.7 | 2129.3 | 2073.6 / 2129.3 |
| 61MP | Adaptive | 128 | 1890.3 | 27.8 | 2073.6 | 2018.0 / 2073.6 |
| 61MP | Adaptive | 64 | 1890.3 | 13.9 | 2045.8 | 1990.1 / 2045.8 |
| 61MP | ISO JPEG | 256 | 1890.3 | 55.7 | 2025.9 | 2025.9 |
| 61MP | ISO JPEG | 128 | 1890.3 | 27.8 | 1970.2 | 1970.2 |
| 61MP | ISO JPEG | 64 | 1890.3 | 13.9 | 1942.4 | 1942.4 |
| 110MP | Adaptive | 256 | 3031.5 | 75.0 | 3328.5 | 3253.5 / 3328.5 |
| 110MP | Adaptive | 128 | 3031.5 | 37.5 | 3253.5 | 3178.5 / 3253.5 |
| 110MP | Adaptive | 64 | 3031.5 | 18.8 | 3216.0 | 3141.0 / 3216.0 |
| 110MP | ISO JPEG | 256 | 3031.5 | 75.0 | 3205.9 | 3205.9 |
| 110MP | ISO JPEG | 128 | 3031.5 | 37.5 | 3130.9 | 3130.9 |
| 110MP | ISO JPEG | 64 | 3031.5 | 18.8 | 3093.4 | 3093.4 |

Both sizes/formats admit full size with 4 GiB **remaining usable export budget**.
A scenario of 5 GiB usable process capacity minus a 1 GiB resident editor leaves
that budget; this is an admission test scenario, not an iPhone 17 Pro measurement.
On iOS the 20% reserve means a 4 GiB export budget requires 5 GiB reported
available *after* the editor is resident. Device RAM alone cannot establish this.

At 3 GiB usable remaining budget, 61MP admits both formats; 110MP RAW with RGB
reservation cannot admit full size in either format even at 64 rows: Adaptive
is short 144.0 MiB (with a 75 MiB slab, 32 MiB codec allowance and fixed 16 MiB
stored-sample workspace); ISO JPEG is short 21.4 MiB. At 4 GiB both formats
admit full size at 256 rows; Adaptive peak is 3328.5 MiB, leaving 767.5 MiB
of that usable budget under the table's stated scope.
The native decoder/work floor alone is 3031.5 MiB. Smaller output cannot remove
that floor; below it, the planner correctly offers no long-edge fallback.
Actual iPhone 17 Pro available memory and a real 110MP RAW remain required to
establish the typical-device result. No constants are lowered to force admission.

## Detached TIFF bitmap ownership

The merged Render source loader (`c89a80ea`, with the R42/R47 tile/gain fixes)
materializes large TIFFs without auxiliary gain once through ImageIO. Its
CGDataProvider retains the decoded native bitmap; CI wraps that backing rather
than introducing another native-size float Render texture. Orientation and
content headroom are preserved. This backing belongs to the **one decoder
allowance**, not an additional area-sized Render owner. Independent editor/export
sources still have independent storage: the resident editor is excluded from
remaining process memory and is never credited as shared export backing.

Render's fresh-process recheck on a 12800×8600 big-endian RGBA half-float TIFF
reports 1695.1 MiB process peak and 4.685 s open+scan+read, compared with the former
CI file-provider path's 2030.1 MiB and 67.288 s. The TIFF's 8 B/native-pixel
bitmap is about 839.8 MiB; even an RGBA float bitmap is 16 B/pixel. The measured
whole-run peak is below this estimator's 3031.5 MiB decoder/work allowance at that
size. The empirical 24 B/pixel + 512 MiB constants and RAW budget table therefore
remain unchanged. This sample does not establish a universal TIFF/Apple decoder
cap or an iPhone footprint guarantee; Render's full measurements are in its
EXPORT_MEMORY.md.

## Timing

Report `stageSeconds.rendering` measures preparation. `stageSeconds.read` sums
only synchronous Render read calls with a monotonic clock; `encoding` excludes
that read time and retains writer/bridge/native verification time. The Mac timing
sample folds `read` into its encoding slot, matching the live encoding stage
that performs pull rendering; its rendering slot remains preparation only.
Total duration and prediction samples remain complete. Old reports without `read` continue to decode.
