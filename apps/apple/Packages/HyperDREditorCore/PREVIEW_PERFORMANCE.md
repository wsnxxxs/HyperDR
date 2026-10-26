# Native detail and comparison performance

Measured on 2026-10-26, macOS 27.0.1, Apple Silicon, SwiftPM debug tests.
These are renderer timings, excluding the canvas's 250 ms idle delay and
display presentation; they are not physical iPhone/iPad measurements.

## Changes

- Opening a detail graph can reuse the existing native 1024-long-edge analysis
  grid. Reuse requires the same source identity (file revision, decoder,
  development, geometry and scene-linear mode) and refuses draft RAW pixels.
  Previously the first zoom developed the entire RAW again for this grid.
  Export's default path still prepares its own analysis.
- The editor renders the visible detail first, then prepares the other
  comparison rendition. Switching comparison keeps both finished details;
  equal renditions share textures and need only one render.
- A pan or comparison switch does not cancel work that already covers the
  new viewport. Overlapping finished detail remains visible while replacement
  work fills the newly exposed area.
- Residency is limited to one detail per rendition, with no history of old
  regions or native RAW cells. Zooming out until the preview has enough pixels,
  closing the photo and yielding to export release the detail frames. Preparing comparison earlier increases
  residency compared with the previous edited-only view, within the same
  two-rendition working set already used by split comparison.

Native RAW cell boundaries, decoder settings, sampling, render algorithms,
preview resolution and exported pixels are unchanged.

## 61MP Sony RAW measurement

Input: local `DSC01468.ARW`, 9504 × 6336, automatic decoder (RAW 9),
1280-pixel preview refined before measurement, exposure +0.5 EV, no look,
2048 × 1536 detail at (3728, 2400).

| Operation | Before | After |
|---|---:|---:|
| First edited detail | 5.844 s | 0.708 s; repeat 0.607 s |
| Original detail after edit | 0.194 s | 0.208 s; repeat 0.170 s |
| Subsequent edited detail | 0.207 s | 0.202 s; repeat 0.160 s |

The first-detail improvement comes from removing the repeated whole-photo
analysis, not reducing detail quality. In the second optimized run, a fresh
export engine independently developed and rendered the same region: maximum
float difference was **0** for both base RGBA and HDR gain. This establishes
equality for this case, not universal CIRAWFilter repeatability.

Run from the repository root with a local RAW (not required by normal tests):

```sh
HYPERDR_DETAIL_BENCHMARK_RAW="$PWD/测试照片/DSC01468.ARW" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path apps/apple/Packages/HyperDREditorCore \
  --scratch-path build-apple/swift-editor-core --filter rawDetailBenchmark
```

Regression coverage checks comparison switches without another render,
visible-rendition priority, identical-rendition sharing, pans during an
in-flight render, partial overlap, export release, native-analysis identity,
draft rejection and pixel agreement with an independent render.

Validation completed: all six Apple Swift package suites; the complete Mac
application test suite (526 tests, two existing skips, no failures on the final
run); unsigned iOS device and simulator builds; localization and preview-timing
tool checks. The live JPEG test now waits for its independent original preview
before asserting comparison mode, instead of assuming the edited frame's
ready state also means the original has finished.

## Remaining limits

Initial native refinement and the first visible ROI still require decoding.
Comparison requested before its detail finishes can still sharpen when the
result arrives. A different RAW development (including a scene-linear look)
cannot reuse another development's analysis. No real 110MP RAW or physical
iOS-device performance/memory measurements were made for this change.

## Film and LUT follow-up (2026-10-26)

The editor now retains the already-developed Apple display and scene-linear
preview/analysis rasters for the current photo. Partial-strength blending and
look metering reuse the matching display textures, including the first movement
below 100% strength. Switching between original and a look restores the matching
preview instead of reopening the RAW. The cache holds at most two developments;
file revision, decoder, geometry and RAW-control changes invalidate it, and
`clearCaches` releases it when closing or yielding to export. Export engines
do not opt into preview retention. No native decoder graph or native cell is kept.

Neutral thumbnails and metering trials no longer evict the live look's blending
baselines. Picker work waits until the main canvas is current. Completed colour
thumbnails survive changes to the selected preset and to excluded physical
effects; actual colour/development changes still rebuild them. Cancelled batches
cannot mark a partially replaced set as complete.

Same 61MP RAW, 1280-pixel preview, automatic RAW 9, Portra 400 with grain and
halation at 100%, followed by Pro 400H and a test identity LUT accepting
S-Log3/S-Gamut3.Cine and outputting sRGB. These measure actual completed renders,
not the time to hide an updating indicator. The LUT is synthetic and does not
represent the cost of every library LUT.

| Operation | Before | After (two runs) |
|---|---:|---:|
| First film application | 11.34 s | 4.56–5.01 s |
| Film strength 100 → 80% | 13.70 s | 0.087 s |
| Further film strength steps | 0.064–0.065 s | 0.079–0.084 s |
| Original → film again | 35.67 s | 0.14–0.16 s |
| Switch film stock | 14.80 s | 0.37–0.40 s |
| Log LUT strength 100 → 80% | 17.12 s | 0.14–0.19 s |

This removes the long stalls rather than accelerating every already-warm GPU
pass. Native RAW development, float precision, film scatter/grain/halation,
LUT interpolation and preview dimensions are unchanged. The real-sample LUT
comparison with an independent fresh engine had maximum float differences of
5.96e-8 (base) and 3.44e-7 (gain). Normal regression tests also compare film and
Log LUT output with independent renders and check cache identity and release.

Reproduce with `HYPERDR_LOOK_BENCHMARK_RAW` instead of
`HYPERDR_DETAIL_BENCHMARK_RAW`, and `--filter rawLookBenchmark` in the command
above. First-time scene-linear development still takes several seconds. Device
memory/performance and real 110MP RAW remain unmeasured; retaining a second
preview increases steady residency when only one development is displayed.

Follow-up validation: `python3.12 scripts/test.py apple` and
`python3.12 scripts/test.py ios` passed. This includes 187 Render tests,
128 editor-core tests, all other package suites, 526 Mac application tests
(two existing skips), both iOS build targets and localization/timing checks.
