# Incremental packaging

ABI 5 provides both whole-plane `hyperdr_package` and incremental row-input
packaging, with the same plane and metadata structure layouts.

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
planes but still has O(compressed file size) container memory. Native verification
now borrows compressed files through a read-only mapping: baseline JPEG uses
scanlines (two gain rows for ISO interpolation), TIFF uses libtiff scanlines and
its strip buffer, and HEIC uses one matching base/gain tile pair plus VT's bounded
in-flight pictures. No native verifier creates full RGB, gain or HDR canvases.
Frame/codebook checks and decoded mat checks run on the staged result before
atomic publication, independently of the normal verify toggle. Destination
publication and CLI encoded bytes are unchanged. File-backed mappings reserve
compressed-file address space and retain reclaimable pages; this is not a full
private encoded-byte allocation. Container item/strip tables still scale with
item/strip count. Render/RAW caches and HEIC's writing-time compressed container
remain separate admission costs.

`verify_encoded_file` retains the original format-specific structural, metadata,
profile, bit-depth/chroma and corruption checks. It additionally visits native
pixels for finite SDR/HDR reconstruction and gain extrema; E5 uses the same
1e-5 relative linear tolerance and 8-pixel coding-block exclusion as the previous
whole-image check. JPEG base and gain decode synchronously with bilinear gain
sampling. HEIC export pairs have matching tile grids, so a pair is reconstructed
one tile at a time, without chroma interpolation across tile boundaries (same as
the normal reader). Progressive/arithmetic JPEG is refused by this bounded export
verifier; HyperDR writes baseline Huffman JPEG. The legacy byte verifier retains
its general JPEG acceptance. TIFF export validation requires the RGB16 layout the
writer emits. Export grids must be upright: EXIF orientation other than 1 and
nonidentity HEIF irot/imir are rejected, including on the gain item. The current
writers emit Orientation=1 and no irot/imir; clean-aperture crops remain supported.
AVIF **remains whole-YUV**: libavif's grid decoder assembles all cells
into one image. Its file verification reports `boundedMemory=false`, and the row
writer capability remains false. System ImageIO verification belongs to Kit.

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

## Verification memory regression

`capi_verify_memory_test` first creates 2048×1024 and 2048×4096 exports in separate
producer processes, then measures fresh verifier processes. TIFF, ISO JPEG and
Adaptive HEIC cover scanlines, paired scanlines and tiles. The producers also
exercise E5 on framed gain-map outputs. No generated file survives a probe. Run
`ctest --test-dir build -R capi_verify_memory_test -V` for actual kernel peak
physical footprints. The threshold allows 16 MiB of allocator/VT variation as
height grows fourfold, rather than the previous full-raster growth.

Measured on macOS in these fresh verifier processes (`TASK_VM_INFO` kernel peak,
bytes; includes framework baseline):

| Format | 2048×1024 | 2048×4096 | Height ×4 growth |
| --- | ---: | ---: | ---: |
| TIFF | 2,327,032 | 2,327,008 | −24 |
| ISO JPEG | 2,523,616 | 2,654,712 | 131,096 |
| Adaptive HEIC | 12,436,128 | 12,534,456 | 98,328 |

The small differences are codec/container tables and allocator variation, rather
than complete float/YUV renditions. This table measures native verification only;
Apple ImageIO verification and Render/RAW memory belong to their respective owners.
