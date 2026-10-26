# ROI editing and export memory contract

## Status: historical RAW repeatability case closed; final Mac checks complete — 2026-10-24

The historical nine-code device discrepancy is closed: controlled request-shape
reproduction and exact comparisons with the original device artifacts established
the cause. The RAW repair uses a fixed native decode grid and a bounded
bitmap-backed cell. This closes the recorded case, not universal repeatability
across cameras, operating systems or hardware.

Film retains full-resolution float32 processing, the four precompiled film
pipeline states and the earlier release of whole-export source ownership. The
isolated PSO/ownership evidence below remains separate from the final RAW comparison.

Formal cap0/cap3 measurements on iPhone and Mac are complete. Retained-cell caching
was deleted because the comparisons did not establish a consistent benefit.
The final configuration without the cache produced identical decoded pixels and
compressed tiles in both Mac RAW scenarios, but speed and memory showed no stable
general improvement. It remains unverified on a physical device or with a real
110MP RAW; see `docs/reviews/raw-repeatability-film-2026-10-23/FINAL-NO-CACHE-2026-10-24.md`.

## Film/LUT and AVIF memory, editor included — 2026-10-24 (Mac only)

Target: a 61MP photo with film or a LUT stays within 2,000,000,000 B of
`phys_footprint` for the whole process, the open editor included, at full size,
float32, with the film unchanged. Measured on the Mac with a Release probe that
links `Shared/Editor` and Kit as the apps do (not in the repository): the real
`RecipeEditor` opens `DSC01468.ARW` (9504 × 6336) on a 2940 × 1912 canvas
(3840 × 2560 preview), applies Portra 400, goes 1:1 and pans twice, then Kit's
`RecipeExportService` exports from its own `RenderEngine`. Footprint is sampled
every 2 ms and checked against the kernel's lifetime peak.

Before (main 8fef3f6a): AVIF used the whole-plane path (5977 MiB with the editor,
5264 without); RAW 9 film 100 % HEIC 1838 MiB with the editor; RAW 9 film 50 %
2250 MiB, its export 272 s because every band reopened the RAW for the Apple
endpoint. Four changes:

1. **PQ/HLG AVIF write from rows** (libavif writer). Rows stage 10-bit RGB
   (6 B/canvas pixel) and the compressed samples in files beside the output; one
   ≤1024² cell and one two-thread encoder are resident. Kit charges 96 B/cell
   pixel + 64 MiB, and system verification 24 B/canvas pixel (ImageIO decodes
   every grid cell for its thumbnail). Cells are predicted independently, so
   bytes and seam codes may differ from a whole-plane AVIF. Encoding this RAW
   takes about 27 s against 10–16 s for HEIC.
2. **A RAW scene look's Apple endpoint is staged once per export**
   (`StagedLookBaseline`). Before the scene graph opens, the export develops the
   endpoint in the canonical cells into an anonymous float32 file (16 B/native
   pixel plus 256 MiB of free space, reserved first; otherwise
   `insufficientStorage`, shown as a storage error), releases that decoder, and
   bands read their window back. Bit-identical to reopening per band
   (`StagedLookBaselineTests`, RAW 8/9, cropped and not). Film 50 % export:
   272 s → 78 s (HEIC HLG), 96 s (AVIF). The Kit estimate still charges the
   second decoder allowance.
3. **The editor yields while an export runs** (`RecipeEditor.yieldToExport` /
   `resumeAfterExport`, Mac and iOS hosts). The captured edit lands first; the
   shown frame and the original (still compared) stay; details, AI and original
   renders stop; `RenderSession` drops its development, detail graph and engine
   caches. Afterwards it develops the same variant once (bit-identical). Editor
   resident 1120 → 618 MiB during a film 50 % export.
4. **Film renders taller than 1024 rows run in 256-row bands**
   (`graphRegionInBands`). Scatter allocated three float32 textures over the
   whole region: ≈450 MiB for the 3840 × 2560 preview, ≈290 MiB for a 1:1 detail.
   A region renders exactly the whole render's pixels (`FilmTests`), so the
   output is bit-identical; no measurable time change. Export bands (≤516 rows)
   are unaffected.

| Fresh process, MiB | Open | Look | 1:1 | Pan | Export max | Resume | Lifetime peak | Export s |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| RAW 9, film 50 %, HEIC HLG (two runs) | 1187 | 1891 / 1931 | 1748 / 1727 | 1862 / 1864 | 1683 / 1700 | 1868 / 1867 | **1894 / 1940** | 78 |
| RAW 9, film 50 %, AVIF PQ | 1188 | 1931 | 1735 | 1864 | 1699 | 1850 | **1931** | 96 |
| RAW 9, film 100 %, AVIF PQ | 1190 | 1664 | 1570 | 1551 | 1486 | 1476 | **1664** | 62 |
| RAW 8, film 50 %, AVIF HLG | 1066 | 1626 | 1436 | 1485 | 1514 | 1530 | **1626** | 89 |
| RAW 9, film 50 %, HEIC HLG, no editor | — | — | — | — | 1206 | — | **1206** | 78 |

2,000,000,000 B is 1907.3 MiB. Every export now stays under it with the editor
open. A partial RAW 9 look is **at the limit** (1.99–2.03 GB): the peak is the
editor applying the look at a 3840 preview, not the export. Then the editor holds
the scene preview (157 MiB), the 4096-edge analysis development (179), the Apple
endpoint (157), the new frame's base and RGB gain (314), the original frame and
the previous frame until it is replaced. Further cuts trade interaction: drop the
original frame while it is not shown (≈200 MiB, peeking renders it again), or
develop the analysis source on demand (every tone edit develops again).

Rejected, measured: releasing only the editor's detail graph (30–130 MiB);
releasing it on reload (no change); clearing the RAW context before the editor's
Apple endpoint (2342–2367 MiB, worse: the editor peak was render workspace and
resident frames, not two decoders); keeping detail and original renders apart on
resume (no change). Not measured on iPhone or iPad, nor with a 110MP RAW.

## Film pipeline reuse and whole-source ownership — 2026-10-23

Local host: Apple M6, 24 GiB, macOS 27.0.1 (26A434), Xcode 27.1 (27A9275).
The film already uses Metal. Its float32 formats, arithmetic and full-resolution
scatter/grain/halation remain unchanged. The missing engine-level states were
`filmMeter`, `graphFilmCells`, `graphFilmExposure` and `filmBlur`: a context's
fallback cache did not escape that command. A diagnostic matrix of five stocks,
SDR/HDR and four exposure/grain/halation/partial-strength variants, each with
whole and ROI output, recorded 222 actual fallback creations before precompiling
and zero afterward. All 25,388,740 Float bit patterns matched.

The ownership experiment uses a **24MP synthetic TIFF**, read as a file through
the complete `RecipeExportService` and ImageIO HEIC path. Both variants already
precompile the four states; their sole difference is Service ownership. The
late whole fallback releases its initial lazy source. Once the collector owns
independent planes and the source revision is rechecked, it consumes the full
source and clears caches. Runtime admission then credits only the retained CPU
resources and collected planes.

Five pairs ran in alternating AB/BA order, each export in a fresh normal Release
process. No concurrent builds, GPU jobs or large-memory jobs ran in the window.
All ten 863,302-byte HEIC files have the same SHA-256. Values below retain every
sample, including the first slow runs; each cell is **min / median / max**.

| Metric | Before | After |
|---|---:|---:|
| Lifetime peak footprint, MiB | 2203.94 / 2205.99 / 2206.33 | 1674.16 / 1676.11 / 1677.24 |
| Process entry through export completion, s | 3.359 / 3.554 / 5.155 | 3.256 / 3.358 / 4.399 |
| Engine initialization plus export, s | 3.293 / 3.494 / 5.035 | 3.195 / 3.299 / 4.325 |
| Service export, s | 3.230 / 3.443 / 4.943 | 3.141 / 3.247 / 4.254 |

Every pair reduces the process peak by **528.81–532.17 MiB** (median 529.52 MiB).
Four pairs finish sooner; one is 0.0166 s slower. The timing ranges overlap, so
this establishes a memory improvement rather than elimination of timing
variance. Process-entry timing includes engine initialization and Kit setup;
the separately saved child wall clock also includes output copying and SHA-256.
The fixed 16 GiB benchmark admission is not physical-device admission evidence.

Weak references prove the complete source texture/image survives encoding and
verification before the change, and is gone before encoding afterward. Its
texture allocation is 387,121,152 bytes. Encoding-stage Metal allocation changes
from 399,441,920 to 720,896 bytes in every pair; sampled stage maxima remain
798,359,552 bytes on both sides. Metal allocation and process footprint describe
different resources and release times. The larger process-peak reduction also
includes native image/analysis ownership; it is not a reduction of film scratch.
A separate diagnostic locates the original process peak during verification,
after the small film tiles, so no extra per-tile command completion was added.

Ten additional pairs control for ordinary photos with film disabled: each fresh
process creates and renders with one engine, then creates a second engine. The
complete initialization distributions in milliseconds are:

| Engine initialization | Before | Four precompiled film states |
|---|---:|---:|
| First in fresh process | 55.70 / 60.03 / 2103.85 | 55.87 / 61.56 / 1628.27 |
| Second in same process | 14.36 / 16.07 / 32.67 | 12.58 / 14.62 / 19.80 |

The ordinary first source/render including initialization has medians 76.82 and
77.38 ms; the second has medians 31.34 and 28.79 ms. These samples do not show a
consistent initialization regression. OS/compiler/file cache state is uncontrolled;
fresh process does not imply a cold system cache. No broader persistent pipeline
cache was introduced.

`RecipeExportReport.renderRows` now records the final reader height when the
executed path uses row input. Whole/ImageIO output leaves it absent, and older
JSON reports without it still decode. A fake-render regression selects 256 and
128 through two actual budgets, observes the prepareRows arguments and matching
report values, and confirms both exports keep the same identity. The field is
diagnostic only; it does not enter `ResolvedExportSnapshot` or `exportKey`.
Historical reports did not record this value, so the recipe alone cannot establish
their actual row setting.

Evidence lives under ignored `build/film-variance/`: `pso-evidence.json`,
`pso-control-{samples,summary,paired-deltas}.json`,
`whole-source-ownership-diagnostic.json`, `scope-formal-v0-paired-{samples,summary}.json`
and their frozen package/source/binary manifests. Symbol checks find no diagnostic
code in the normal Release binaries. These isolated PSO/ownership measurements
are distinct from the completed cap0/cap3 comparison and final Mac RAW comparison
summarized above.

## Historical stop and device status — 2026-10-21

The user stopped optimization on 2026-10-21. At that point no further experiments
were scheduled; the CPU writer-conversion route remained the default and the
opt-in Metal writer experiment had no validated net HIF benefit. That experiment
and its measurements predate the current canonical RAW backend. The later RAW
repeatability failure remains recorded below.

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

In Automatic, new photos prefer CIRAWFilter decoder 9, then 8, retaining the exact
`9` / `9.dng` or `8` / `8.dng` identity in the recipe. Cameras without either use
their supported older system default. Forced RAW 8/9 requires that generation.
Existing recipes with no decoder field keep the system default. Every RAW read
uses an extended-linear sRGB working CIContext and converts to extended-linear P3 at output; decoder 9 loses red
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
Later formal cap0/cap3 and final Mac RAW comparisons are separate application
benchmarks, summarized above. This table is the earlier Mac backend measurement,
not the final application's performance result.

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
uses the existing 4096 × 516 source bound; its Apple endpoint is staged once
(see the 2026-10-24 section above) rather than developed again for each band. Partial looks can produce RGB gain;
writers that require mono use the existing explicit reconstruction/resplit path.

`Recipe.needsLookBaseline` travels through editor preflight and is recomputed
from the frozen recipe by RecipeExportService. The row estimate reserves a second
24 B/native-pixel decoder allowance; whole-plane fallback also charges its source
texture. The conservative GPU tile bound includes one extra RGBAf source texture.
The usual 110MP/4 GiB estimate below applies to a single development, **not** to
RAW film/SDR-output scene looks or other partial scene looks. Zero strength
without stock effects and ordinary display-space LUTs keep the single-development
allowance. No new physical-device timing or memory claim is
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
- Unframed output normalizes and packs RGB32 into shared Metal buffers in the
  consumer's command. Its completed command and intermediate textures leave the
  rendering pool before independent Swift arrays are copied; the base buffer is
  released before copying gain. Framed output retains texture composition and
  vImage packing. Admission conservatively retains the previous packing bound:
  28 bytes per tile pixel for mono gain and 40 for RGB gain, beside canvas-row
  arrays when horizontal stitching is needed. The maximum output tile has
  2,097,152 pixels; this optimization does not reduce the decoder reservation.
- An active film reserves three overlapping RGBA float32 textures for linear
  exposure, its horizontal pass and accumulated scatter: **48 B/tile-pixel**,
  at most **96.75 MiB** against the 4096 x 516 source bound. Half-float storage
  both lost ordinary SDR shadow codes and clipped bright film exposure before
  scattering. The film's source halo still shrinks lazy output tiles to retain
  that bound. Editor preflight and the frozen export use the same recipe facts;
  disabled/zero-strength film does not add this reservation. It overlaps row
  rendering/encoding, and is released before assembly and verification. The
  whole-plane fallback's existing 64 B/photo-pixel allowance covers these
  three textures. No new physical-device memory measurement is claimed.
- HDR summary preparation visits every photo tile once, keeps five summary
  words and metadata, and retains no tile outputs. SDR-only output renders one
  tile for provenance and checks finite inputs and alpha while reading every
  stripe, avoiding the unused full-photo gain summary. `read` never repeats
  summary preparation. Export pair conversion joins the consuming command and
  omits local display-peak reductions; the first authored HDR band retains the
  legacy headroom fallback, and the global HDR summary remains authoritative.
  It uses its private renderer's persistent CIContext, queue, compiled kernels,
  lazy source graph and frozen analysis. The original RenderEngine remains free.
- Frames/shadows are composed per output tile; captions are cropped before
  rasterization. Frame/gain alignment and writer metadata remain unchanged.

Every production Render texture allocation validates the Metal GPU-family limit
before calling `makeTexture`: Simulator **8192**, Apple family 3+/Mac family 2
**16384**, older families 8192. Shared display allocations use the same check.
Oversized logical canvases use tiled export/ROI rendering; an explicitly requested
single texture beyond the limit throws `invalidSize` rather than Metal aborting.

## Canonical RAW decode scratch — 2026-10-23

RAW materialization decodes a fixed grid on the complete geometry-applied image:
each inner cell is at most **2044 x 256**, with a fixed two-pixel halo clipped only
at the image boundary. A completed cell supplies its inner pixels to the requested
ROI. There is no full-image pixel cache. Preview, fixed analysis/model input,
full loads, lazy export/detail ROIs and partial-look baselines use this path.

One bitmap-backed cell is at most
**2048 x 260 x 16 = 8,519,680 bytes (8.125 MiB)**, beside the requested output.
Each cell is validated and copied, then its command completes and its autorelease
pool drains before the next development. No completed cell is retained for a
later tile or row read. Partial looks develop their endpoints serially. Opaque
retries keep the same rectangle and fail after three incomplete developments;
canonical cells do not use adaptive splitting.

Single-cell workspace uses the existing bounded ROI working-set allowance;
there is no additional completed-cell reservation. The **24 B/native-pixel +
512 MiB** decoder/work reservation, the second native allowance for RAW display
looks, film workspace and the 20% available-memory reserve remain in place.
These are conservative allocation estimates, not device-memory measurements.
Performance and validation status are summarized at the start of this document.

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
Full loads also detach large TIFF bitmaps: concurrent Core Image rendering of
the original ImageIO provider omitted complete tiles despite intact native data.
Ordinary RAW exports reuse their open full development for fixed analysis;
scene-linear Log/film exports keep independent analysis after sharing that graph
increased measured opening memory. Both paths retain the same decoder allowance.

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
At that point the cause was undetermined. The later controlled request-shape
reproduction and exact original-artifact comparisons closed this historical
case, as described at the start of this document. Do not use the 14.67 s run as
a quality-qualified speedup, or infer that the GPU path alone caused the discrepancy.

A fresh RAW launch with the pre-encode audit enabled was prepared, but the user
stopped optimization before another export ran in that 2026-10-21 session.
The phone was returned to the CPU route and audit disabled. Later RAW 8/9 audit
and controlled repeatability comparisons are covered by the final report. Recorded lifetime
VT-boundary peaks: RAW Metal 1121.1 MiB / CPU 1111.7 MiB; these include earlier
editor/decode work and do not establish a universal memory bound.

Evidence: `build/device-qa/2026-10-21/metal/`, including both RAW comparisons,
all four outputs/reports, timing/memory traces and the unresolved-status summary.

The subsequent on-device audit and repeated controls addressed that diagnostic
step. A possible future performance experiment is a frozen Render graph ROI feeding
float32 Metal textures and encoder surfaces without intermediate CPU float
arrays. It would need a GPU handoff across Render/Kit/engine, preserving
cancellation, revisions, codebook/CLLI statistics, frame zero gain and both
verification paths. This work is deferred, not scheduled or in progress.

## Deferred checks and handoff

- Measure a **real 110MP RAW on the iPhone** before claiming support. The current
  estimate admits 4 GiB remaining usable export budget after the process reserve,
  not 3 GiB; retain
  24 B/native pixel + 512 MiB plus rows, resources and resident editor.
- The completed formal phone comparison has zero gain for RAW 8 and about
  0.13008 stops for RAW 9. It does not establish performance under strong HDR
  highlights. The final configuration after cache deletion still needs device
  validation; Mac pixel equality does not establish phone speed or footprint.
- Keep 256-row admission as the default. The old Mac 512-row experiment saved
  little and doubled row storage; a device experiment must justify changing it.
- Render APIs retain revision checks and the public 512-row read limit. No C ABI
  change. Oversized logical canvases use bounded tiles, never full-canvas GPU textures.
- Historical 2026-10-21 follow-up validation: eight native targeted tests (including zero,
  tiny nonzero and framed gain replay/equality checks), eight absolute quality
  cases plus E5, unsigned iOS device/simulator builds, and both full-size device
  initial exports with zero changed decoded codes. That historical Apple suite
  passed (481 Mac app tests, two skipped); those passes alone did not resolve
  the later RAW failure, which was subsequently closed by the artifact comparisons
  described above. Do not infer jetsam from signal 9
  without a termination report.

## Independent grain and halation

Generic effects use no full-resolution scatter textures. Halation uses the same
bounded analysis-cell budget as film (≤768 long edge): two RGBAf cell textures
and one temporary separable-blur texture, ≤27 MiB for a square grid. The fixed
512 MiB ROI/analysis allowance in Kit already covers this budget regardless of
`usesFilm`; the extra per-tile film allowance remains exclusive to stock scatter.
Grain uses the bundled Portra particle table and small kernel buffer, without a
full-image noise texture. Both effects run in 256-row bands when the region is
taller than 1024 rows. Zero amounts allocate no generic effect workspace.
Generic effects require no extra decoder or staged Apple endpoint. A selected
stock with nonzero grain/halation continues to require scene-linear RAW and
scatter even at zero stock colour strength. Since 2026-10-26 it also requires the
Apple display baseline at every colour strength, 100 % included (captured HDR
below), so `needsLookBaseline` and Kit's `usesFilm` charge both developments and
the existing scatter workspace. The independent stock effect is the difference
of its complete and effect-free outputs: one extra `filmFromRaw` per pixel
whenever grain or halation is nonzero, at any colour strength, held in shader
registers without another full-resolution texture. Only a stock without grain or
halation evaluates `filmFromRaw` once; the Kodak green balance reuses the
effect-free output instead of adding another.


### Single render pass for HDR row packaging (2026-10-25)

AVIF, PQ/HLG HEIC and gain-map row writers now pull each rendered band only
once. The complete finite scan still measures exact min/max and the same
stratified gamma sample. It simultaneously writes the tight RGB base and
mono/RGB gain as float32 to an anonymous file beside the package output.
Encoding reuses the package band to read that file; no half conversion or
widened gain range changes quantization, offsets or E5 zero alignment.

The file is exclusively created with close-on-exec, immediately unlinked,
marked `F_NOCACHE` and physically preallocated before rendering. Disk use is
16 B/canvas pixel (mono gain) or 24 B/canvas pixel (RGB gain): about 1.45 GB
at 60.2MP RGB, 2.64 GB at 110MP RGB, separate from AVIF's existing RGB16 and
compressed sample files and any staged RAW look baseline. Insufficient storage
fails before pulling the first band. Closing on success, cancellation or error
reclaims the allocation. It adds no resident image, mmap or full-size cache.

Kit's estimate takes the maximum of render/readback and replay/codec workspace
for gain formats, since rendering no longer overlaps AV1/VT encoding. SDR
writers retain their direct callback estimate. The 110MP admission and 61MP
footprint goals remain unchanged; physical-device validation is still required.


Mac spot check: Apple M6 / 24 GB, macOS 27.0.1, release benchmark,
DSC01468.ARW (9504×6336, RAW 9), Captured, no film/frame/live editor,
AVIF PQ q100, 256-row input, fixed two-stop range, 4 GiB admission budget.
Separate fresh processes, run sequentially with no builds/tests beside them:

| Metric | Before (77352dcd writer) | Float32 replay |
| --- | ---: | ---: |
| Total export | 46.121 s | 42.984 s |
| Row renderer time | 4.145 s (two passes) | 2.397 s (one pass) |
| Encoding, excluding row renderer | 26.123 s | 26.556 s |
| Independent system verification | 2.585 s | 2.737 s |
| Kernel peak physical footprint | 1,172,293,552 B (1118.0 MiB) | 1,206,585,384 B (1150.7 MiB) |
| Output | 44,921,645 B | 44,921,645 B |

This single pair is 6.8% faster overall and spends 42.2% less time in the row
renderer. Decoder/analysis time also varies between fresh processes, so the
whole-export difference is not entirely attributable to replay. Both peaks
remain below decimal 2 GB; the modest peak variation does not reflect an
image-sized RAM cache. The conservative estimate still requires more than a
2 GB admission budget; the benchmark's `under2GB` reports measured footprint,
independently of that budget. This is a Mac measurement, not a device claim.

Before/after encoded bytes match exactly (SHA-256
`097b7cdd1d706250f9692f30eac792dd944aff745b562b0c01572e6eeb3f462a`).
A separate default-recipe comparison (automatic range, same RAW 9) built both
Render and the macOS engine from 2ab8e535 and compared them with this version.
Both produced the same 44,921,645-byte file and SHA-256, despite the encoder's
two/four-thread setting. Decoded 10-bit YUV444 samples match exactly (maximum
code difference 0, infinite PSNR). The reported 59.7 MB → 42.4 MB change was
not reproduced with the same default Captured recipe; that recipe uses no AI,
so the research-model offset changes do not apply to this comparison.

The remaining final verification time is Kit's independent ImageIO HDR
thumbnail readback (`ExportVerification.boundedSystem`), which visits AVIF
cells to produce the thumbnail. Native `verify_avif_file` only checks structure
and sample digests for the already-decoded cells; matching cells do not decode
again. Retain the independent reader until a separate change deliberately
revisits that verification contract.

To reproduce, build `scripts/bench_export_memory.swift` as a release executable
with Kit/Render/Recipe/Engine dependencies. Set `HYPERDR_BENCH_QUALITY=100` and
`HYPERDR_BENCH_BUDGET_BYTES=4294967296`; leave range at its benchmark default
of 2 for the timing pair, or set `HYPERDR_BENCH_RANGE_STOPS=auto` for the
unmodified default recipe. Generated files/reports are local under `build/`.


The Kit disk preflight now admits the simultaneous storage demand before RAW
or row development: any pending RAW look baseline (16 B/native pixel), the
float32 replay (conservative RGB 24 B/final canvas pixel), AVIF RGB16 staging
(6 B/canvas pixel), estimated compressed samples and final result (8 B/pixel
each), plus the existing 256 MiB reserve. It checks again before row preparation
using only the remaining demand once the RAW baseline is allocated. Thus a
110MP RGB AVIF needs about 5.06 GB plus the reserve after baseline allocation,
not just its 2.64 GB replay. The native spool preallocation remains mandatory.
`ENOSPC`/`EDQUOT` from replay allocation, AVIF sample/staging writes or final
assembly now cross ABI 5 as additive `insufficient_storage`; Kit maps these
and POSIX/Cocoa disk-full failures to its localized insufficient-storage error.


Encoded disk estimates follow each writer's owners: SDR TIFF reserves one
RGB16 output with 0.1% Deflate/strip overhead and 1 MiB metadata allowance;
SDR JPEG reserves one 4:2:0 worst-case JPEG buffer (MCU-padded libjpeg-turbo
formula) plus 1 MiB metadata. A 60MP SDR TIFF therefore needs 629,844,032 B
including the 256 MiB reserve, not two encoded files. ISO JPEG row output
counts base/auxiliary component files plus their assembled result; native HEIC
counts its compressed sample picture(s) plus the final container. ImageIO
Adaptive writes one destination from in-memory pictures. AVIF's row path keeps
its sample spool plus result; whole-plane AVIF assembles in memory.


## Captured HDR through display looks — 2026-10-26

Full-strength RAW film and Log-to-SDR looks now use the Apple display development
as their captured HDR reference as well. Previously only partial strength (and
zero-colour physical effects) retained it; full Log-to-SDR LUTs recomputed gain
from their bounded output and lost HDR, while a dark print multiplied down the
captured highlight brightness. Colour remains the physical print/LUT rendition;
highlight luminance is protected separately and fades in below reference white.
It cannot demand more captured headroom than the unstyled reference. HDR-output
LUT transforms remain explicit. SDR pixels do not change when HDR is toggled.

`Recipe.needsLookBaseline` now stages/prices full RAW film and full Log-to-SDR
looks too, preserving the existing two-development allowance and 16 B/native
pixel staging requirement. Preview and analysis retain their bounded Apple
rasters; metering detached tiny textures does not evict them. No extra full-size
raster is retained. The staged decoder still closes before scene development.
No new physical-device timing or memory claim is made here.

Stock grain/halation are independent RGB deltas at full as well as partial colour
strength. Physical effects use an offset-aware RGB gain pair and cap only actual
HDR overflow at the selected ceiling. The row estimator already reserves RGB gain.

Private reproduction and measurements are in
`docs/reviews/look-hdr-2026-10-26/RESULTS.md` (ignored).

### Full-strength film export cost on the Mac — 2026-10-26

`scripts/bench_export_memory.swift`, Release, one fresh process per case, no
editor: `DSC01468.ARW` (9504 × 6336, RAW 9), Portra 400 at 100 %, film exposure
0, range 2 stops, quality 90, `HYPERDR_BENCH_BUDGET_BYTES=4294967296`. "Before"
is a65f711e with bd5165c6 reverted (its baseline guard restored by hand), so it
differs only in the captured-HDR change; "after" is a65f711e. Grain/halation 100 %
is what choosing a stock on an untouched photo applies; the script itself leaves
them at 0, so a local copy set both through an environment variable.

| Case | Before s | After s | Before peak MiB | After peak MiB | Kit estimate MiB |
|---|---:|---:|---:|---:|---:|
| HEIC HLG, grain/halation 0 | 12.8 | 33.3 | 1243 | 1292 | 2122 → 3500 |
| AVIF PQ, grain/halation 0 | 20.1 | 40.6 | 1244 | 1292 | 2142 → 3520 |
| HEIC HLG, grain/halation 100 % (two runs) | 12.6 / 13.0 | 32.0 / 32.7 | 1244 / 1253 | 1313 / 1315 | 2122 → 3500 |
| AVIF PQ, grain/halation 100 % (two runs) | 23.4 / 24.5 | 42.6 / 44.4 | 1254 / 1252 | 1317 / 1315 | 2142 → 3520 |

Every export verified, and the peak stays far under 2,000,000,000 B (1907.3 MiB);
memory rises only 50–70 MiB. Time rises by about 20 s per export (HEIC 2.5×, AVIF
1.8×), all of it in three stages: developing 3 → 12.5–13 s (staging the Apple
endpoint in native cells), rendering 4.7 → 12 s (each band evaluates the baseline
scene as well) and read 2 → 4.7 s (reading the staged file back). Encoding and
verification do not change. The staged file needs 963,526,656 B of free space
plus the 256 MiB reserve. With the bench's default 2 GB budget both versions are
blocked (`export_memory_exceeded`): the estimate already exceeded it before this
change and grows by 1378 MiB for the second development allowance, while the
measured peak grows by under 70 MiB. These Mac figures are not comparable to the
2026-10-24 table above, which measured a real editor's phases with an
older pipeline. Not measured on iPhone or iPad, nor with a 110MP RAW.

### Skip unused RAW references for SDR output — 2026-10-27

Full-strength film and SDR-output Log looks now skip the Apple display endpoint
when the final output is SDR, either by format or by the HDR switch. Partial
strength and zero-colour stock effects retain it for the SDR crossfade. Recipe,
Kit memory/storage admission, staging, automatic resolution and band rendering
share that output intent. The analysis key includes the RAW reference requirement
so returning to HDR cannot reuse SDR-only statistics. SDR exports also skip AI
gain inference; Adaptive HEIC with HDR off no longer requests a gain plane or
whole-photo gain summary. The frozen recipe in export history is unchanged.

Release on the same 61MP RAW above, Portra 400, film exposure 0, grain/halation
100%, quality 90, range 2, 4 GiB admission budget, no editor; fresh process per
case, comparing the previous a65f711e binary to this working tree:

| SDR JPEG at 100%, HDR off | Before | After |
|---|---:|---:|
| Export seconds | 29.89 | 11.08 |
| Peak footprint MiB | 1356.5 | 1314.2 |
| Kit estimate MiB | 3421.3 | 2043.0 |
| RAW baseline staging bytes | 963,526,656 | 0 |

Both JPEGs decode to identical pixels (maximum 8-bit code error 0); only two ICC
creation-timestamp bytes differ. At 40% the staging/estimate remains unchanged
and decoded pixels are identical. The HLG 100% control exports are byte-identical.
An SDR-format/HDR-on run also produces identical pixels and the same reduced
estimate, but took 21.28 s; partial/HDR timing also varied substantially. These
single runs establish the eliminated work, not a stable speedup across devices.
No new device/110MP claim or reduced native decoder cap is made.

`scripts/bench_export_memory.swift` now accepts `HYPERDR_BENCH_EFFECTS=100` and
`HYPERDR_BENCH_HDR=0/1` and reports the effective export baseline requirement.
All measurements and comparisons: `docs/reviews/sdr-look-export-2026-10-27/RESULTS.md`
(ignored). Recipe's 39 and Kit's 237 tests pass, as do staged RAW 8/9 baseline,
SDR/HDR look, geometry, effects and export regressions; the Mac app builds.
