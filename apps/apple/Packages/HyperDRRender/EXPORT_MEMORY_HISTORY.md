# Historical export memory and timing experiments

These Mac measurements document why the current bounds were chosen. They are not
current iPhone performance results. See [the current contract and device results](EXPORT_MEMORY.md).

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

### Native-tiled RAW preview follow-up

The reduced `CIRAWFilter.scaleFactor` path was the controllable source of an
extra high-water mark. Preview and fixed analysis now keep the filter at native
scale, develop independent <=4096 x 516 ROIs and area-filter each into the bounded
float32 preview/analysis texture. RAW settings and
draft mode are unchanged. `RAWDevelopment.scaleFactor` reports the final source
output scale, including this post-development resampling. Analysis remains
1024-long-edge and the processing graph remains <=768-long-edge.

Fresh-process before/after, same 60,217,344-pixel RAW, 2048 preview, fixed analysis,
four 2048-square details/pans, 256-row export reads, Mac Debug. The editor's preview,
latest display output and lazy detail source remain alive during the combined
export; independent export starts without them. Peaks are process MiB:

| Stage | Reduced filter preview | Initial native ROI point preview |
|---|---:|---:|
| Open + fixed analysis | 1530.7 | 1236.7 |
| Open + first 1:1 detail + four pans | 1723.3 | 1254.2 |
| Independent export open/scan/read | 1571.9 | 1337.8 |
| Export open/scan/read with resident editor | 1958.9 | 1492.8 |

This reduces the measured peaks by 19.2%, 27.2%, 14.9% and 23.8%, respectively.
Opening/analysis took 1.035 -> 1.722 s; through the pans 2.010 -> 2.879 s;
the combined run 5.033 -> 5.734 s. Independent export took 3.671 -> 3.244 s.
A repeat without changes peaked at 1801.6 MiB while panning; native ROI preview
repeats peaked at 1245.9/1254.2 MiB. Apple resource release timing still varies.
The earlier RAW tables/projections above describe the previous preview policy.

An isolated system graph was 25.7/26.0 MiB before any development. Rendering a
1024 preview previously peaked at 1158.8 MiB, versus 1016.8 MiB now (917.3 MiB
resident after the last tile). Subtracting graph residency and the 11,599,872-byte
owned destination gives about **19.5 -> 17.1 peak B/native pixel**, or **15.3
resident B/native pixel** after the new preview. This includes system development
and its ROI work, not just a separately measurable decoder cache. A native
2048-square ROI alone peaked at 338.8 MiB, including its 70,270,976-byte output:
a detail ROI does not require an application-owned full-frame development.

`clearCaches` after development, extra autorelease pools and recreating the
CIContext did not reliably reduce the complete-run peak. Preview draft mode did
not reduce the opening peak. Reducing the CI memory target to 64 MB increased the
peak to 2979.3 MiB; it is not a monotonic process-memory limit. A half-float working
context lowered memory but changed sampled linear/normalized outputs by up to
0.01448 (15 ticks on a 1023 scale), so it was rejected. Production keeps float32,
`cacheIntermediates = false` and the 256 MB task target.

The original point-sampling preview test could not detect downsampling aliasing.
It is replaced by an independent CPU area reference over one-pixel alternating
stripes, in both axes: 9504 x 16 -> 1024 x 1 (and its transpose), plus 1 x 1
outputs whose footprints cross native tile boundaries. Maximum absolute float32
error is 8.94e-8. Each ROI covers the full destination footprints plus a one-texel
rounding guard. Footprints exceeding the native envelope are integrated in
bounded pieces; their partial area sums accumulate without truncation. Full/ROI
rendering and replay checks remain in place. No native-size Render texture was added.
The editor/exporter can hold separate lazy RAW graphs and Apple cache storage;
neither retains an application-owned full-size float development. Their measured
overlap is still charged as resident editor state, not credited as shared memory.
Keep **24 B/native pixel once + 512 MiB**, plus rows/resources/resident editor,
as the empirical admission allowance: this sample does not justify a lower
universal bound or certify a 110MP RAW on an iPhone.

### Area-filter follow-up (R50)

Same fresh-process probe, 60,217,344 native pixels, 2048 preview + automatic
analysis + display, four 2048-square pans and a complete 256-row export read
with the editor retained. Process peak MiB:

| Stage | Reduced filter | Native point sampling | Native area filtering |
|---|---:|---:|---:|
| Open + fixed analysis + display | 1530.5 | 1237.0 | 1216.0 |
| Through four 1:1 pans | 1799.7 | 1239.6 | 1408.4 |
| Through export scan/read with resident editor | 1963.6 | 1492.5 | 1676.4 |

Area-filter repeat: 1196.3 / 1413.2 / 1684.7 MiB. Thus the opening reduction
remains, and pan/export peaks remain below the reduced-filter path, but their
previous point-sampling savings are partly lost. These are whole-process peaks,
including system caches; the <=4096 x 516 source envelope and empirical 24 B/px
allowance are unchanged. Complete area-filter probe: 6.20 s (repeat 6.19 s).

For the licensed Sony fixture, resolved automatic `hdr.range` is 0.8117584
with the reduced-filter path, 0.8825801 with native point sampling and 0.8563057
with native area filtering. Area filtering differs from the original by +0.0445473
and from point sampling by -0.0262744. Native versus reduced RAW development is
still different; this change removes point-sampling aliasing, not that system
pipeline difference. The 61MP probe resolves to 0 in all three paths.

### Synthetic TIFF measurements

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
bounded. These historical Mac measurements do not establish an iPhone footprint bound; current device results are in [EXPORT_MEMORY.md](EXPORT_MEMORY.md).

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
This historical implementation made three image passes for metadata/statistics and encoding. The current PQ/HLG writer uses two, with CLLI fused into encoding. Keep 256
for lower memory; 512 saved little time here and requires twice the row storage.
The service's `encoding` clock includes synchronous pull rendering; `rendering`
is preparation only. These are Mac results, not an iPhone performance guarantee.
