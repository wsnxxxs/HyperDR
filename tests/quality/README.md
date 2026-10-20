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
`_SPEED`, `_FPS`, `_CBR`, `_REORDER` (all prefixed `HYPERDR_LAB`). `_TRACE=1`
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
