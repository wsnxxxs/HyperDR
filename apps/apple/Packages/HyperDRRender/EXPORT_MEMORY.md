# ROI editing and export memory contract

## Status: optimization stopped at user request — 2026-10-21

Keep the CPU route as the default. The Metal experiment is opt-in only and is
not approved as a faster or fully validated replacement. No further optimization
or device experiments are scheduled. Existing full-size exports succeeded, but
**a later RAW repeatability comparison failed**; see the unresolved issue below.
Do not treat earlier zero-difference comparisons as a universal quality guarantee.

## Current device status — 2026-10-21

Physical iPhone 17 Pro `Hydrogen`, Personal Team, optimized
`HyperDRiOS-Release`, q90, original dimensions, resident editor, unchanged
20% process reserve and export verification. Times sum persisted service stage
clocks, excluding the user's Save to Files action. The HIF is about 60MP;
there is no 12MP camera fixture or real 110MP RAW in this device run.

| Input / output | Dimensions | First successful Debug | Release + CLLI fusion | Current follow-up |
|---|---:|---:|---:|---:|
| A7R V DSC01468.ARW / Adaptive HDR | 9504 × 6336 | 66.59 s | 19.78 s | **16.37 s** |
| Sony DSC01422.HIF / HEIC HLG | 6336 × 9504 | 58.65 s | 7.55 s | **7.41 s** |

Both full-size exports pass native verification and independent system readback.
RAW was opened at 1:1 and panned without a crash. Its unchanged automatic recipe
resolves to **zero gain** for this photo; it still stores a full-resolution mono
gain image. HIF readback retains 2.2234 stops, 10-bit BT.2100 HLG.
Before/after comparisons find **zero changed decoded codes** across 194,248,704
RAW samples and 97,124,352 HIF samples, including padded Y/Cb/Cr tiles and gain.
The comparator also checks dimensions, precision/chroma, nclx, CLLI and gain metadata.
Results vary with device thermal state and recipe; this is not a universal speed guarantee.

RAW's latest export is 17.2% shorter than the preceding Release measurement.
Its Render read time falls from 8.70 to 5.70 s; the auxiliary VT producer drops
from 3.33 to 0.24 s after removing source replay. HIF's 7.55→7.41 s difference
is small and may include run variance; it is not claimed as a significant speedup.
These are individual device runs, not a statistical benchmark.

Evidence: ignored `build/device-qa/2026-10-21/` (memory change), `speed/`
(Release/CLLI), and `speed-followup/` (zero-gain/matrix reuse). Each contains
persisted reports, outputs, comparisons and timing traces.
Before the compressed-sample spool change RAW preflight blocked at rounded
2.3 GB needed / 2.3 GB available; HIF runtime admission reported 2226 MiB needed /
2094 MiB available. No admission bypass or extra memory entitlement was used.

## Current performance decisions

- Use the Release scheme for performance measurements. C++ was already optimized;
  Debug Swift callback validation, copies and thumbnail work inflated the original
  times. Release alone changed the HIF from 58.37 s to 9.56 s.
- PQ/HLG accumulate CLLI while feeding encoding rows, preserving native sample and
  reduction order. This removes a complete render/reconstruction pass: two passes
  remain (codebook + encoding). Adaptive normally requires three.
- After a complete finite-sample scan proves exact zero gain, the row writer can
  generate gain codes without replaying the source. It retains the same codebook,
  quantizer, deterministic dither and frame checks. Nonzero gain still replays.
  On this RAW it reduces source passes from three to two, without retaining a
  whole image or adding a disk cache.
- PQ/HLG also reuse the linear P3→Rec.2020 matrix result from CLLI
  accumulation in the encoding slab. No extra buffer, precision change or
  different luminance reduction is introduced.
- `HYPERDR_HEVC_TIMINGS=1` reports VT hardware selection, producer, wait and submit
  timing, plus full Swift callback and Render read time. The measured sessions
  report `hw=1`; device backpressure/flush costs were negligible. The `encoding`
  stage includes synchronous producer/callback work, not only hardware encoding.
- Float32, original dimensions, calibrated q90 mapping, non-real-time VT mode,
  four pictures in flight and both verification paths remain unchanged.

[Historical Mac experiments and 110MP projections](EXPORT_MEMORY_HISTORY.md)
explain the memory allowance, rejected precision/cache changes and earlier timings.

## System RAW 9 backend measurement — 2026-10-22 (Mac only)

New photos choose CIRAWFilter decoder 9 when supported, retaining the exact
`9` / `9.dng` identity in the recipe. Existing recipes with no decoder field
keep the system default. Every RAW read uses an extended-linear sRGB working
CIContext and converts to extended-linear P3 at output; decoder 9 loses red
with a P3 working context. Other rendering stays in P3.

Mac, macOS 27.0.1, Apple M6, `DSC01468.ARW`, 9504 × 6336 (60,217,344
pixels, marketed as 61MP), optimized standalone Swift/Metal CIContext,
RGBAf output, boost 1, exposure 0, EDR 1, contrast/local tone map 0,
cacheIntermediates false, memoryTarget 256. One fresh process per decoder/mode;
three reads reuse the same graph. Warm times include decoder-internal reuse,
so they are not independent developments. This is a backend decode benchmark,
not application export timing. `/usr/bin/time -l` records process peaks including
output storage and framework/Metal memory; RSS and footprint are different metrics.

| Mode | Decoder | First read | Reused graph reads 2 / 3 | Peak RSS | Peak footprint |
|---|---|---:|---:|---:|---:|
| Full RGBAf bitmap | 8 | 0.916 s | 0.578 / 0.574 s | 1341 MiB | 2329 MiB |
| Full RGBAf bitmap | 9 | 2.254 s | 0.235 / 0.207 s | 1415 MiB | 2715 MiB |
| One native 4096 × 516 ROI | 8 | 0.075 s | 0.019 / 0.017 s | 153 MiB | 398 MiB |
| One native 4096 × 516 ROI | 9 | 0.163 s | 0.005 / 0.007 s | 172 MiB | 426 MiB |
| Whole image via ≤4096 × 516 native ROIs | 8 | 0.913 s | 0.707 / 0.607 s | 404 MiB | 1060 MiB |
| Whole image via ≤4096 × 516 native ROIs | 9 | 2.414 s | 0.266 / 0.299 s | 397 MiB | 1472 MiB |

The first decoder-9 process also spent 4.703 s opening the filter/loading the
system model before the first read (other setup times 0.188–0.234 s).
Evidence and benchmark source: ignored `build/denoise/raw9-backend/`.

The row allowance stays **24 B/native-pixel + 512 MiB**: at this size it
reserves 1890 MiB, above the measured 1472 MiB scan footprint. The whole-plane
fallback now uses that same decoder allowance beside its 16 B/pixel source
texture and 32 MiB fixed reserve (2841 MiB at this size), replacing its old
16 B/native-pixel decoder reserve. The measured RAW 9 full footprint (2715 MiB)
exceeded the old allowance. Admission tests cover the revised fallback.
**iPhone/iPad RAW 9 memory and performance have not been measured.** These Mac
numbers do not establish 110MP RAW 9 admission or repeatability on a device.

## Editing and render bounds

The editor uses a lazy `ExportSource` for details on every platform. A detail
request develops only its native ROI plus sampling support. It never calls
`load(.full)`. RAW preview pixels are detached from their development graph;
changing RAW settings releases the previous detail graph before opening another.
Only the newest edited/original detail outputs are held by the editor.

## Partial RAW look crossfade (2026-10-22)

Log LUTs and built-in film are alternative looks. Strength between zero and one
requires the scene development and the neutral Apple display development to
preserve both endpoints. `lookBaseline` materializes one matching preview/ROI;
only its latest texture is cached, never a collection of visited tiles. Export
uses the existing 4096 × 516 source bound. Partial looks can produce RGB gain;
writers that require mono use the existing explicit reconstruction/resplit path.

`Recipe.needsLookBaseline` travels through editor preflight and is recomputed
from the frozen recipe by RecipeExportService. The row estimate reserves a second
24 B/native-pixel decoder allowance; whole-plane fallback also charges its source
texture. The conservative GPU tile bound includes one extra RGBAf source texture.
The usual 110MP/4 GiB estimate below applies to a single development, **not** to
a partial scene look. Zero/full strength and ordinary display-space LUTs keep the
single-development allowance. No new physical-device timing or memory claim is
made for this path.

## Render-owned export bounds

- `PreparedExportRows.maximumReadRows` is **512**. Larger reads throw
  `RenderError.invalidRegion`; 256 remains the smaller-memory choice. Arbitrary
  replay and global pixel coordinates are preserved.
- `PreparedExportRows.maximumSourceTileSize` is **4096 x 516**, including the
  two-native-texel base halo on each side. The gain map gets one native texel of
  support, and its own native dimensions also constrain the tile selection.
- Output work tiles are at most **4096 x 512**. Both horizontal and vertical
  subdivision are used, including when a downscale projects a small output
  region onto a much larger native region. No canvas-wide GPU intermediate is
  allocated. Larger detail ROIs are additionally rasterized into independent
  516-row CI destinations and blitted into the bounded detail texture.
- Analysis always uses a 1024-long-edge source and at most a 768-long-edge graph.
  There is one analysis cache, one current author/HDR working cache and one LUT
  cache. None is indexed by every visited detail tile. AI retains four small
  predictions. LUT/model/caption resources remain separately chargeable.
- The output of one read has exactly `4 * (3 + gainChannels) * width * count`
  bytes of owned floats. At 12800 wide and 256 rows that is 50 MiB (mono) or
  75 MiB (RGB gain); 512 rows doubles those values. Wider canvases therefore
  cost wider **CPU row buffers**, not a wider GPU texture.
- RGB packing uses vImage and releases the base RGBA scratch before reading
  gain. The packing scratch/output high-water is 28 bytes per tile pixel for
  mono gain and 40 for RGB gain, in addition to the canvas-row arrays when
  horizontal stitching is needed. The maximum output tile has 2,097,152 pixels.
- Summary preparation visits every photo tile once, keeps five summary words
  and metadata, and retains no tile outputs. `read` never repeats this scan.
  It uses its private renderer's persistent CIContext, queue, compiled kernels,
  lazy source graph and frozen analysis. The original RenderEngine remains free.
- Frames/shadows are composed per output tile; captions are cropped before
  rasterization. Frame/gain alignment and writer metadata remain unchanged.

Every production Render texture allocation validates the Metal GPU-family limit
before calling `makeTexture`: Simulator **8192**, Apple family 3+/Mac family 2
**16384**, older families 8192. Shared display allocations use the same check.
Oversized logical canvases use tiled export/ROI rendering; an explicitly requested
single texture beyond the limit throws `invalidSize` rather than Metal aborting.

## Apple decoder memory is not a constant

The bounds above apply to Render's allocations, **not** Apple's decoder storage.
Public ImageIO/CIRAWFilter APIs do not provide a hard memory limit for that
storage. CIContext uses `cacheIntermediates = false` and `memoryTarget = 256` MB;
that is a render-task target, not a process/decoder cap.

In particular, our 61MP RAW's first reduced development used approximately
**20 bytes per native pixel** of additional footprint, despite its 1024/2048
output size. Filter construction/outputImage graph creation itself was only
14–28 MB total process footprint. Draft mode and the CI memory target did not
remove the native-size decode allocation. Cropped native developments and cache
cleanup later released most of it. Large TIFFs without auxiliary gain now
materialize ImageIO's native bitmap once and detach the TIFF provider, preserving
bit depth, color space, alpha, decode values and headroom. This is native decoder
storage, not a full-size RGBAf Render texture. It remains resident with the export
source and is charged to the native-area allowance. Other large rasters keep CI's
file provider; bounded <=4096 rasters keep the cheaper ImageIO CGImage provider.

**Do not replace Apple's native-area item with a fixed constant.** Remove the
retired full RGBAf *Render source/output/composite* items; retain one decoder
working-set allowance. Native auxiliary gain-map data, LUTs, caption PNG/decoded
resources and the caller's resident editor state are additional real owners.
There is no verified universal byte/pixel upper bound for every camera/codec.

## File-backed HEVC output tiles (iPhone follow-up, 2026-10-21)

The row writer no longer retains all compressed HEVC samples until HEIF
assembly. Each completed VT picture is written into an anonymous staging-directory
file, with file caching disabled. Only per-tile offsets and lengths remain in
memory. Validation and assembly read one tile at a time; the existing 256 KiB
sink-write and cancellation bounds remain. File handles close on success and
exceptions, including callback/storage failures. Files are unlinked immediately
and cannot be orphaned by a terminated process.

Each encoded 512-pixel tile has an enforced 4 MiB storage bound. Kit reserves
16 MiB for callback input/repacking, stored-sample reads and bounded indexing,
instead of the former whole-canvas compressed-rate envelope. The empirical
**24 B/native pixel + 512 MiB** decode/ROI allowance, process-memory safety
margin, returned row owners, encoding slab, VT pictures and verification are
unchanged. There is no new entitlement, precision change, or output downscale.
The tradeoff is temporary disk space proportional to the compressed output.
Legacy whole-plane/in-memory codec APIs keep their existing sequence ownership.

Public API investigation:

- [UsingHardwareAcceleratedVideoEncoder](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder)
  confirms actual session selection; the device reports hardware in all measured streams.
- [MaxFrameDelayCount](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxframedelaycount)
  bounds the encoder's compression window. The lab's attempted value 3 returned
  -12900 on the Mac encoder; device traces showed no flush/wait bottleneck,
  so no product setting was changed.
- [ExpectedFrameRate](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_expectedframerate)
  is an initialization hint. A 60-fps Mac lab experiment did not materially
  change throughput or decoded quality and was not adopted.
- [PrioritizeEncodingSpeedOverQuality](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_prioritizeencodingspeedoverquality)
  explicitly permits sacrificing quality. It was not enabled. The calibrated
  quality route, non-real-time mode and four-picture in-flight bound remain.


## GPU-to-encoder tile experiment — 2026-10-21

Apple documents IOSurface-backed CVPixelBuffer pools with Metal views of each
Y/chroma plane, so GPU output can feed HEVC without an extra frame copy:
[Create image processing apps powered by Apple silicon, HEVC case study](https://developer.apple.com/videos/play/wwdc2021/10153/?time=1710).

Implemented as an **opt-in experiment**, `HYPERDR_METAL_HEVC=1`: the row writer
reads transfer-encoded RGB into one reusable 3 MiB shared Metal buffer. A 512-pixel
tile kernel writes Y/chroma directly into VT's own IOSurface planes; completion
is awaited before submission. Four pictures remain the maximum in flight. Gain
pictures, transfer functions and HDR reconstruction retain the CPU reference.
The default remains CPU. This stage still includes GPU→CPU float readback and
CPU→GPU input packing; it is not a complete zero-copy render pipeline.

Safe/precise Metal math and disabled contraction are necessary. The initial
prototype differed at two pre-encode YUV samples, expanding to a two-code decoded
error, and was rejected. After aligning arithmetic, native source-code tests and the initial
full-size device comparisons had zero differences. A later RAW comparison
failed as recorded below; RAW cross-run quality validation remains open. The audit flag computes the
CPU YUV reference and rejects any difference before VT; it is disabled for timing.

Same-build fresh-process iPhone HIF comparison, q90, original dimensions:
CPU **7.19 s**, Metal **7.28 s**. VT wrapper totals are 2.8728 and 2.8580 s;
submission falls from 0.2143 to 0.0566 s, but input production rises from 2.6498
to 2.7927 s. Removing the final copy alone provides **no net device speedup**.
Lifetime process peaks at the final VT boundary were 881.8 MiB CPU / 875.3 MiB
Metal; these individual runs include earlier editor/decode work and their small
difference is not evidence of a general memory saving. Both use the normal
memory admission and both verification paths.

RAW's initial Metal export took 15.97 s and matched the earlier 16.37 s CPU
reference exactly. A later same-build CPU run took 14.67 s, but differed from
both references by up to **9 decoded codes** (37,918,881 changed samples across
194,248,704, mean squared code difference 0.4131698094). Source digest, recipe,
resolved snapshot and options matched. Both files passed native structural and
independent system readback. Those checks do not establish pixel repeatability.
The cause is **undetermined**; neither RAW rendering variability nor the Metal
conversion has been isolated. Do not use the 14.67 s run as a quality-qualified
speedup, or infer that the GPU path alone caused the discrepancy.

A fresh RAW launch with the pre-encode audit enabled was prepared, but the user
stopped optimization before another export ran. No further audit result exists.
The phone was returned to the CPU route and audit disabled. Recorded lifetime
VT-boundary peaks: RAW Metal 1121.1 MiB / CPU 1111.7 MiB; these include earlier
editor/decode work and do not establish a universal memory bound.

Evidence: `build/device-qa/2026-10-21/metal/`, including both RAW comparisons,
all four outputs/reports, timing/memory traces and the unresolved-status summary.

If optimization is explicitly resumed later, first isolate RAW repeatability
with an on-device pre-encode audit and repeated identical-source controls. A
possible later performance experiment is a frozen Render graph ROI feeding
float32 Metal textures and encoder surfaces without intermediate CPU float
arrays. It would need a GPU handoff across Render/Kit/engine, preserving
cancellation, revisions, codebook/CLLI statistics, frame zero gain and both
verification paths. This work is deferred, not scheduled or in progress.

## Deferred checks and handoff

- Measure a **real 110MP RAW on the iPhone** before claiming support. The current
  estimate admits roughly 4 GiB available process memory, not 3 GiB; retain
  24 B/native pixel + 512 MiB plus rows, resources and resident editor.
- Current RAW measurements use a zero-gain automatic recipe. Measure nonzero
  HDR edits separately before generalizing its speedup to all RAW exports.
- Keep 256-row admission as the default. The old Mac 512-row experiment saved
  little and doubled row storage; a device experiment must justify changing it.
- Render APIs retain revision checks and the public 512-row read limit. No C ABI
  change. Oversized logical canvases use bounded tiles, never full-canvas GPU textures.
- Latest follow-up validation: eight native targeted tests (including zero,
  tiny nonzero and framed gain replay/equality checks), eight absolute quality
  cases plus E5, unsigned iOS device/simulator builds, and both full-size device
  initial exports with zero changed decoded codes. The later RAW repeatability
  failure above remains unresolved. The final full Apple suite passed (481 Mac
  app tests, two skipped); these test passes do not waive the RAW failure. Do not infer jetsam from signal 9
  without a termination report.
