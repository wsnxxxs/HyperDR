# ROI editing and export memory contract

The editor uses a lazy `ExportSource` for details on every platform. A detail
request develops only its native ROI plus sampling support. It never calls
`load(.full)`. RAW preview pixels are detached from their development graph;
changing RAW settings releases the previous detail graph before opening another.
Only the newest edited/original detail outputs are held by the editor.

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

## Measurements and 110MP projection

Apple M6, 24 GiB, macOS/Xcode 27 SDK, debug Swift build; `task_vm_info.phys_footprint`
and `ledger_phys_footprint_peak`. No taskpolicy throttling. RAW input is
9504 x 6336 = 60,217,344 pixels; target is 12800 x 8600 = 110,080,000, ratio 1.828.
Only numeric results are recorded. Temporary synthetic files/probes are removed.

| Stage | 61MP RAW measured footprint / peak MiB | 110MP RAW: conservative whole-peak linear projection MiB |
|---|---:|---:|
| Old editor full load + four pans | 5715.5 peak | 10448.2 |
| New preview + fixed analysis | 1531.4 peak | 2799.5 |
| New lazy detail graph opened | 1207.3 resident (this run) | 2207.0 |
| New first 2048-square detail + four pans | 1531.4 peak; 497.1 resident after last pan | 2799.5 peak |
| Independent export source opened | 1162.2 resident/peak | 2124.6 |
| Independent global preparation scan | 1555.4 peak; 669.5 resident after scan | 2843.3 peak |
| Independent reads, 256 rows | no increase above 1555.4 peak; 749.1 resident after reads | <=2843.3 whole-run peak |

A nearby 512-row internal-tile experiment reached 1689.1 MiB while editing; this
is evidence that ARC/decoder resource timing affects the high-water mark. Treat
roughly **1.7 GiB at 61MP / 3.1 GiB at 110MP** as the conservative editing
measurement envelope, not a certified iPhone ceiling. The final 516-row run
completed opening and four pans in 2.66 s (old 3.18 s); steady pans took
approximately 0.06–0.20 s each. The first detail includes graph setup.

A less pessimistic source-area-plus-fixed-ROI projection uses measured 20 B/native
pixel and keeps the remaining peak fixed: about **2483 MiB editing** and
**2506 MiB export preparation** at 110MP. This is a projection for this RAW,
not a guaranteed bound. A practical admission estimate may reserve **24 B/native
pixel once, plus 512 MiB** for mono RAW export work, then add returned CPU row
arrays, retained resources and the existing editor. This is an empirical safety
allowance, not a replacement for checking available process memory. Do not credit
native caches across independent engines without measuring their overlap.

| 110.08MP synthetic TIFF, final editor implementation | Measured MiB |
|---|---:|
| Preview + fixed analysis peak | 195.0 |
| Lazy source opening peak | 776.3 |
| Four 2048-square details/pans peak | 1560.5 |
| Global export scan peak | 1660.5 |
| Complete read pass peak | 1738.1 |

The original TIFF scan/read run took 83.6 s (32 s scan, 44.7 s reads), excluding
HEVC encoding. Profiling isolated repeated ImageIO TIFF strip decoding and
16-bit byte swapping during CI ROI rasterization, rather than GPU processing or
RGB packing. The recheck uses an uncompressed, big-endian RGBA half-float TIFF with
one row per strip: decompression itself was not the cause. ImageIO/CI immediate
cache hints alone did not stop the repeated decoding.

A fresh-process before/after recheck on the same pre-generated 12800 x 8600 TIFF,
Mac Debug, 256-row reads (file generation excluded):

| Native TIFF provider | Open s | Global scan s | Complete read pass s | Total s | Process peak MiB |
|---|---:|---:|---:|---:|---:|
| Previous CI file provider | 8.142 | 55.905 | 3.241 | 67.288 | 2030.1 |
| Detached native bitmap | 2.366 | 0.557 | 1.763 | 4.685 | 1695.1 |

This recheck is 14.4x faster overall; decoder cache timing makes the previous
scan/read split variable between runs. All existing Render tile/row limits stay
unchanged; no native-size GPU source or float processing buffer was added.

The final internal detail subdivision was separately rechecked (7.23 s for
opening/four pans); it did not increase the whole-export peak envelope. A
20017-wide synthetic image also covers both sides of the 16384 limit, exact
replay, frame zero gain and an oversized caption.

We cannot certify "all 110MP RAWs fit a 3 GiB process budget" from this sample.
A real 110MP RAW and on-device QA are still required; under memory pressure,
admission must refuse work before decode rather than assume Apple's caches are
bounded. No iPhone footprint/timing result is claimed here.

## 12MP HLG export timing

4032 x 3024 synthetic HLG gradient, q90, native rows writer, bounded verification
on. The old RGB pack loop was reinstated temporarily on the same source/writer
to isolate its contribution; the probe was removed afterward.

| Readback | Rows | Reads across all writer passes | Prepare s | Package+verify s | Synchronous read total s |
|---|---:|---:|---:|---:|---:|
| Old per-pixel ArraySlice append | 256 | 36 | 0.097 | 6.671 | 5.718 |
| vImage RGB packing | 256 | 36 | 0.069 | 1.474 | 0.904 |
| vImage RGB packing | 512 | 18 | 0.069 | 1.416 | 0.864 |

There is no per-read CIContext, pipeline compilation or analysis scan. HEIC's
512-row slab consumes two sequential 256-row callbacks (one with 512); the native
writer caches its current input band, so pixel-row access does not render again.
Three image passes are expected for metadata/statistics and encoding. Keep 256
for lower memory; 512 saved little time here and requires twice the row storage.
The service's `encoding` clock includes synchronous pull rendering; `rendering`
is preparation only. These are Mac results, not an iPhone performance guarantee.

## Interface changes and handoff

- `RenderEngine.materializeExportRegion(_:outputSize:region:)` exposes native ROI
  materialization to the shared editor, retaining source revision checks.
- `RenderEngine.maximumTextureDimension(device:)` exposes the allocation limit
  to the shared canvas. Existing render/load entry signatures are unchanged.
- Prepared rows keep their synchronous read signature, with the public 512-row
  maximum above; current Kit's 256-row reads remain valid. No C ABI changes.
- Full `scripts/test.py apple` passed: Render 46 and EditorCore 36 tests, Mac app
  477 tests (2 skipped), package tests, localization and timing self-test.
  `scripts/test.py ios` passed device and simulator builds. All used Python 3.12,
  Xcode and a private TMPDIR.

Next owner should retest zoom/pan and HLG export on iPhone, measure a real 110MP
RAW if available, and update Kit admission using the split decoder/tile/row
ownership above. Signal 9 is consistent with the former footprint but is not a
confirmed jetsam diagnosis without the device termination report. The decoder
allowance is still empirical. Export stage timing attribution remains unchanged.
The 110MP TIFF CPU decompression cost also remains; this change bounds Render's
allocations rather than replacing Apple's codec. Draft RAW, subdividing preview
renders, and optional RAW opener reordering were measured and discarded because
they provided no benefit or increased peak memory. No unfinished experimental
code or sample-derived files are retained.
