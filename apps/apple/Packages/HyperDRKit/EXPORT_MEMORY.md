# Export admission after tiled Render

The row path follows HyperDRRender/EXPORT_MEMORY.md. Full-plane writers (AVIF,
ImageIO) still price their actual whole-plane owners and may be refused.
All figures below are estimates, not measured iPhone footprints.

For native area N, canvas width W and callback height R:

- Decoder/work allowance D = 24N + 512 MiB, once. This is empirical, from the
  Render measurements, not a universal Apple decoder cap. Sensor area is used
  if larger than the developed raster. Reducing the output does not shrink N.
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
  one compressed sequence C. Since `bc394adc`, assembly retains only C and
  streams the container into the staged file; both full-plane and row package
  paths use the file sink. Items and <=256 KiB writes borrow spans, so there is
  no extra chunk allocation or complete output vector. The existing 32 MiB
  assembly allowance covers bounded metadata/box construction (Exif/XMP are
  individually limited to 4 MiB) and the small standard-library file buffer.
  C is the existing quality/depth rate envelope, now charged once.
  JPEG adds 32W codec workspace. Stage peaks are compared, not summed.
- Native/system verification keeps the same decoder/work allowance plus bounded
  row/tile and thumbnail workspace. `maxAdmissibleLongEdge` uses this same
  estimator, including the invariant native decoder floor. It binary-searches
  only scalar memory estimates (at most about 14 candidates for a 12800 edge),
  without constructing a full plan for each pixel of the rejected long edge.

## RAW budget table

MiB, q95, Adaptive Main10, no frame/LUT/caption, RGB gain reservation (even though
separated RAW normally uses mono). Values can be reproduced with
`HYPERDR_MEMORY_ESTIMATES=1 swift test --filter fullSizeRAWMemoryEstimates`.
61MP means 9504×6336 (60.22MP); 110MP means 12800×8600 (110.08MP).
The final column separates assembly / peak where they differ; Adaptive now
peaks during encoding, while its float slab and VT workspace are still alive.

| Native | Format | Rows | D | Returned B | Encode | Assembly / peak |
|---|---|---:|---:|---:|---:|---:|
| 61MP | Adaptive | 256 | 1890.3 | 55.7 | 2321.8 | 2266.1 / 2321.8 |
| 61MP | Adaptive | 128 | 1890.3 | 27.8 | 2266.1 | 2210.4 / 2266.1 |
| 61MP | Adaptive | 64 | 1890.3 | 13.9 | 2238.2 | 2182.6 / 2238.2 |
| 61MP | ISO JPEG | 256 | 1890.3 | 55.7 | 2025.9 | 2025.9 |
| 61MP | ISO JPEG | 128 | 1890.3 | 27.8 | 1970.2 | 1970.2 |
| 61MP | ISO JPEG | 64 | 1890.3 | 13.9 | 1942.4 | 1942.4 |
| 110MP | Adaptive | 256 | 3031.5 | 75.0 | 3691.9 | 3616.9 / 3691.9 |
| 110MP | Adaptive | 128 | 3031.5 | 37.5 | 3616.9 | 3541.9 / 3616.9 |
| 110MP | Adaptive | 64 | 3031.5 | 18.8 | 3579.4 | 3504.4 / 3579.4 |
| 110MP | ISO JPEG | 256 | 3031.5 | 75.0 | 3205.9 | 3205.9 |
| 110MP | ISO JPEG | 128 | 3031.5 | 37.5 | 3130.9 | 3130.9 |
| 110MP | ISO JPEG | 64 | 3031.5 | 18.8 | 3093.4 | 3093.4 |

Both sizes/formats admit full size with 4 GiB **remaining usable export budget**.
A scenario of 5 GiB usable process capacity minus a 1 GiB resident editor leaves
that budget; this is an admission test scenario, not an iPhone 17 Pro measurement.
On iOS the 20% reserve means a 4 GiB export budget requires 5 GiB reported
available *after* the editor is resident. Device RAM alone cannot establish this.

At 3 GiB usable remaining budget, 61MP admits both formats; 110MP RAW with RGB
reservation cannot admit either even at 64 rows: Adaptive is short 507.4 MiB
(its remaining single compressed sequence is 379.4 MiB, with a 75 MiB slab and
32 MiB codec workspace); ISO JPEG is still short 21.4 MiB. At 4 GiB both formats
continue to admit full size at 256 rows; Adaptive peak is now 3691.9 MiB, leaving
404.1 MiB rather than 99.7 MiB of that usable budget.
The native decoder/work floor alone is 3031.5 MiB. Smaller output cannot remove
that floor; below it, the planner correctly offers no long-edge fallback.
Actual iPhone 17 Pro available memory and a real 110MP RAW remain required to
establish the typical-device result. No constants are lowered to force admission.

## Timing

Report `stageSeconds.rendering` measures preparation. `stageSeconds.read` sums
only synchronous Render read calls with a monotonic clock; `encoding` excludes
that read time and retains writer/bridge/native verification time. The Mac timing
sample folds `read` into its rendering slot so total duration and prediction
samples remain complete. Old reports without `read` continue to decode.
