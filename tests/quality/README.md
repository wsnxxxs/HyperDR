# Local HEVC quality gate

Build `quality_lab` explicitly (it is excluded from normal builds):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer cmake --build build --target quality_lab e5_package_quality
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer taskpolicy -b python3.12 tests/quality/run.py --build-dir build --e5
```

Use a private `TMPDIR` when another native suite runs concurrently. The runner
uses synthetic gradients, saturated edges/skin tones and a mat. Candidate files
are deleted with its temporary directory. `--report path.json` saves numbers.
There is no CI job or hosted runner. The package E5 cases generate finished float planes and compare framed output
with the same unframed photograph. The .02-stop mean and 1% peak limits remain;
package also checks zero-code alignment and bounded mat readback. The eight
renderer-specific frozen baselines retired with that renderer (P7-4).

The lab compares the **same linear P3 input** through ImageIO and our real
package entry. Main8-only `native-nearest sdr` exercises the shared HEIC base
encoder without a gain map (the engine has no public SDR-HEIC package format).
PQ and HLG are always Main10; `depth` must not silently lower them to Main8.
Gain-map storage stays 8-bit for both Adaptive base depths.

`quality_lab run WRITER FORMAT DEPTH QUALITY SCENE WIDTH HEIGHT OUTPUT [PHOTO]`
prints coded base/gain sizes, encoding time, native-decoded Y-PSNR and HDR
PSNR-PQ, ITU BT.2124 delta-E ITP percentiles, peak/mean luminance, gain PSNR and
mat maximum gain. Y-PSNR uses BT.709 weights on transfer-encoded P3 RGB. The
system Y-PSNR is also measured independently via ImageIO/CI in linear P3 before
applying the same metric. These numbers must not be compared directly with an
older report's RGB-PSNR. Gain PSNR uses the full two-stop reference range.
Dimensions, direction, bit depth, primaries/transfer, gain presence/channels,
headroom and gain coding metadata are checked independently of quality limits.
The primary/gain ICC and container behavior remain covered by codec tests.

Writers: `imageio` forces 512 tiles; `imageio-auto` lets the system choose;
`package` / `fast` invoke the actual whole-plane package path. `native` and
`native-nearest` isolate YUV dithering with a simple gamma-1 nearest gain map;
they intentionally do **not** reproduce package gain quantization. Scenes are
`analytic`, `ramp`, `edges`, `frame`. Optional PHOTO is read-only, resized/cropped with
ImageIO, and its metadata is never copied into the output or JSON. Do not use
private photos as test fixtures or commit candidate images.

For controlled public-VT property experiments, explicitly build
`quality_vt_trace` and load its dylib with `DYLD_INSERT_LIBRARIES` **after**
`taskpolicy`. Overrides: `HYPERDR_LAB_QUALITY`, `_GAIN_QUALITY`, `_HARDWARE`,
`_SPEED`, `_FPS`, `_DELAY`, `_CBR`, `_REORDER` (all prefixed `HYPERDR_LAB`). `_TRACE=1`
logs actual readable properties and status codes. The interposer is never
linked into product binaries. It does not observe ImageIO's private encoder;
absence of intercepted public VT calls is not evidence about private settings.
Do not use background-priority runs for timing comparisons. The emitted time
covers input quantization, encode and write, excluding decode and metrics.

P3a-2 intentionally changes the product RGB-to-YUV quantizer, not the old
ImageIO test's TPDF-floor fixture. That historical floor and its margins remain
untouched. This runner adds absolute limits for the new production path, plus
an intermediate one-stop reconstruction of the two-stop Adaptive pair.

The neutral ramp gate also checks adjacent code steps and the flat-sample
fraction against the measured ImageIO result; it does not claim to replace a
subjective gradient review. Threshold reference: Apple M6 / macOS 27.0.1.

## Device-export comparisons

`quality_lab compare BEFORE.heic AFTER.heic` checks matching native dimensions,
bit depth, chroma layout, nclx, content-light levels, gain presence and ISO gain
coding metadata, then compares every decoded native Y/Cb/Cr code (including
coded tile padding and gain tiles). It prints sample counts, maximum code error
and mean squared error, and fails above one code. This is a before/after export
regression check, complementary to the absolute fidelity and E5 gates above;
container byte equality is not used as the quality criterion. One image's
native coded-picture buffers are retained, never full float RGB reconstructions.

Set `HYPERDR_HEVC_TIMINGS=1` in an app's launch environment to record VT setup,
input production, backpressure wait, submission, completion and selected hardware
status. Kit also reports total callback time beside the Render-only read time.
The latter distinction matters: Debug Swift callback validation/thumbnail work
is charged to encoding in the normal stage report. Use the shared
`HyperDRiOS-Release` scheme for on-device performance measurements.

## Experimental direct Metal surfaces

The row HEIC writer's opt-in `HYPERDR_METAL_HEVC=1` uses a bounded 512×512
Metal converter to write VideoToolbox's IOSurface Y/chroma planes directly.
Transfer functions and gain reconstruction remain on the CPU. Default exports
retain the CPU route pending an end-to-end benefit. `HYPERDR_METAL_AUDIT=1`
additionally computes the CPU YUV reference before each submission and rejects
any source-code difference; use this for correctness, never for timing.

`metal_yuv_test` checks exact YUV codes at 8/10 bits, matrices 709/2020,
PQ/HLG/linear test values and partial edge tiles. Safe Metal math, precise
functions and disabled contraction match the engine's `-ffp-contract=off`.
The test skips only when no Metal device exists.

To exercise the absolute quality lab's supported package cases through rows:

```sh
HYPERDR_QUALITY_ROWS=1 HYPERDR_METAL_HEVC=1 HYPERDR_METAL_AUDIT=1 \
  python3.12 tests/quality/run.py --build-dir build --e5 --report /tmp/metal-quality.json
```

`HYPERDR_QUALITY_ROWS` affects only the lab's package cases whose format supports
rows; the native-nearest SDR control and separate E5 binary keep their own paths.
Native framed row checks also run in `capi_package_rows_test` with the Metal flag.
Device before/after comparisons remain necessary. The 2026-10-21 RAW repeat
comparison failed at up to nine decoded codes despite matching recipe/source;
its cause remains unresolved. Optimization stopped at the user's request, and
this route stays experimental. See Render's `EXPORT_MEMORY.md` for evidence. `HEVC_MEMORY` timing diagnostics
include process footprint and lifetime peak at session boundaries; they are not
an isolated allocator measurement or a universal codec-memory bound.
