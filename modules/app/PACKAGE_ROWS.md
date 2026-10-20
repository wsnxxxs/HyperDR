# Incremental packaging

ABI 4 is retained: this change adds symbols, changes no existing structure layout
and leaves `hyperdr_package` and CLI output behavior intact.

`hyperdr_package_rows_supported(format)` reports compiled row-input capability.
`hyperdr_package_rows(engine, request, rows, callback, user, report, error)` runs
synchronously. Request planes supply complete canvas dimensions/channel count and
F32 format; data, size and row_bytes are ignored. Offsets, headrooms, gamut, Exif,
quality, presentation_frame and frame_photo retain their whole-plane meanings.
The callback fills borrowed tight RGB base/log2 gain buffers and returns before
encoding continues. It is serialized, may revisit rows, and must be repeatable.
The native token and callback failures abort before publishing the staged file.
No asynchronous queues or full-plane spool is hidden behind this entry.

The Swift entry is `Engine.packageRows(width:height:gainChannels:gainMetadata:
rows:to:options:read:)`; the throwing synchronous reader receives y/count and
borrowed mutable float buffers. Its original Swift error is preserved.
`Engine.supportsPackageRows(format:)` exposes the capability query.

| Writer | Row-input implementation | Resident encoded output |
| --- | --- | --- |
| SDR JPEG | scanlines, fixed Huffman tables | stdio buffer |
| SDR TIFF | libtiff scanlines/deflate strips | stdio/strip buffers |
| ISO JPEG | separate base and gain JPEG streams in temporary files, MPF/ISO assembly in 64 KiB blocks | stdio buffers |
| Adaptive HEIC, PQ/HLG HEIC | full-width 512-row slab, serial VT tile production | compressed tiles and container bytes retained |
| AVIF PQ/HLG | **unsupported**, fall back to whole-plane | libavif currently retains all YUV grid cells |

JPEG's optimized Huffman pass needs whole-frame DCT coefficients. Streaming uses
fixed tables instead; its entropy bytes/MPF sizes change, while quantizers,
sampling, dither, gain gamma and decoded pixel codes remain the same. Existing
whole-plane/CLI entropy optimization is unchanged. Framed gain JPEG keeps quality
100 and exact zero alignment. TIFF's tags/strip layout and lossless bytes match.

Gain extrema and the exact same stratified gamma sample (at most 65,536 samples)
are measured before encoding. Sampling indices, normalization, rational metadata,
zero alignment and global dither coordinates match whole-plane packaging. Base
and gain encoding can replay bands; the caller must preserve the frozen render
source and recipe. `rows` controls the input slab (1..4096, default/recommended
256); HEIC additionally needs its own 512-row source slab. Source/Render memory
is separate and belongs in admission too.

Memory scope: TIFF/JPEG write directly to staged files, without output-byte
vectors or full float planes. HEIC removes full float input/reconstruction/YUV
planes but still has O(compressed file size) container memory. **Verification is
still whole-image**, after the input band is released; both normal verify and E5
readback must be budgeted separately. This entry does not claim bounded end-to-end
memory or change Photos/Kit behavior. Frame input/codebook checks and decoded mat
checks run on the staged result before atomic publication, independently of the
normal verify toggle. Destination overwrite/no-overwrite behavior is preserved.

## Measured writer memory

Separate fresh macOS processes, synthetic 2048-pixel-wide SDR TIFF gradients,
verify=false, no caller float plane on the row path. `TASK_VM_INFO` kernel peak
physical footprint includes the engine/framework baseline (~11.8 MB):

| Input | Band rows | Peak physical footprint |
| --- | ---: | ---: |
| 2048×1024, rows | 64 | 13,926,880 B |
| 2048×4096, rows | 64 | 14,008,824 B |
| 2048×4096, rows | 512 | 25,018,872 B |
| 2048×4096, whole-plane | n/a | 219,841,184 B |

Four times the image height adds only ~82 KB on the row path; raising the band
from 64 to 512 adds ~11.0 MB, matching the extra RGB float band. The full-plane
baseline includes its caller-owned input, the package copy and encoding output.
This measures writing, not verification or Render/RAW residency, and does not
claim the HEIC compressed-container buffer is constant-sized.
Repeat with `build/capi_package_rows_test stream 4096 64`, changing height/rows,
or `build/capi_package_rows_test full 4096 64`; each run removes its generated
file. `capi_package_rows_test` without arguments checks all supported formats,
frame/cancel/failure behavior and whole/rows agreement. Tests freeze ICC creation
time using the repository's test clock: TIFF and Adaptive/PQ/HLG HEIC match
byte-for-byte; SDR/ISO JPEG entropy differs with zero decoded pixel difference.
