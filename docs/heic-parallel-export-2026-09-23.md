# Parallel HEIC export

Large Adaptive, PQ, and HLG HEIC exports now encode independent tiles in private
libheif contexts, then assemble the HEIF grids in a fixed row-major order.
The existing 2048-pixel tiles, edge padding, quality, bit depth, chroma handling,
and x265 preset are unchanged. Full-resolution gain maps use the same workers.
Small images retain the previous single-image path.

The default is `clamp(logical_cpu_count / 4, 1, 4)` simultaneous tile jobs.
Each x265 instance retains its own internal threads. The diagnostic environment
variable `HYPERDR_HEIC_TILE_WORKERS=1` selects the original serial path; 2–4
override the automatic count.

The container assembler copies encoded HEVC payloads and their properties,
creates hidden tile items and grid references, attaches Exif/XMP to the primary
image, and retains the existing Adaptive TMAP adapter. Container layout and
the generated ICC creation timestamp can differ; reconstructed pixels do not.
The assembler follows libheif's serial output where it has a choice: a grid's
`pixi` association is essential and Exif/XMP items are hidden. Item types,
hidden flags and property associations then match the serial file item for item.

x265 fills a process-wide primitive table on its first encoder open and checks
a single entry to decide whether that has happened, so concurrent first opens
can observe a half-filled table. Before starting tile workers, the encoder opens
one 64 × 64 picture per bit depth, once per process, on the calling thread.

Windows' Main10/8-bit dual x265 runtime also needs a loader fix. x265 4.2's
process-wide recursion counter races during concurrent fallback API lookups.
`scripts/prepare_x265_multibit.ps1` now applies a thread-local counter before
building Main10. Existing source builds must rerun that script once; the new
release package already includes the corrected DLL. Prewarming the DLL alone
would not fix this race because each tile performs an API lookup.

## Measurements

Windows, Intel Core Ultra 5 245K, 14 cores / 14 logical processors. Input:
`output/DSC02120-lossless/adaptive/DSC02120-hyperdr.heic`, 9504 × 6336 pixels.
Adaptive output, quality 90, default 8-bit depth and `slow` preset, full-size
gain map, output verification enabled. No simultaneous build or export ran
during these measurements.

| Run | Serial codec / total | Parallel codec / total |
| --- | --- | --- |
| 1 | 16.673 / 22.915 s | 10.059 / 15.827 s |
| 2 | 15.675 / 21.448 s | 10.403 / 16.223 s |
| 3 | 15.462 / 21.249 s | 10.632 / 16.539 s |
| Median | 15.675 / 21.448 s | 10.403 / 16.223 s |

Parallel runs use three workers, automatically selected on this machine.
The first parallel sample used an explicit three-worker override; subsequent
samples used the default. Codec time falls 33.6%; total time falls 24.4%.
Total is `decode_ms + process_ms + encode_ms`, including output self-verification
and writing. Individual exploratory two-/four-worker runs took 12.422/10.333
seconds in the codec; three workers avoid the extra fourth encoder at similar
speed. Results are specific to this image and machine.

Reports and output files are under `output/parallel-heic/`: `serial-large*.json`,
`parallel3-large.json`, and `default-large-*.json`. The pre-change executable
and DLLs are retained there in `serial-bin/` for reproduction.

## Validation

- `heif_parallel_test`: parallel-first fresh-process encoding, Adaptive 8-bit
  slow and 10-bit medium, PQ/HLG, odd edges, row-major compressed tile bytes,
  decoded pixels, ICC/nclx, Exif/XMP, CLLI, and TMAP metadata. ICC comparison
  excludes only its 12-byte creation timestamp.
- `heif_grid_test`, `codec_test`, `inspect_test`, and `iso_gain_map_test` passed.
- The real 60 MP file has identical payloads for all 40 HEVC tiles, both grids,
  TMAP, Exif, and XMP. Full-resolution HDR comparison covers 60,217,344 pixels:
  PSNR is identical and all reported delta E ITP values are zero.
- The packaged executable passed clean-extraction conversion/self-verification
  for all six output formats. Apple hardware playback was not tested here.

The ZIP is `output/parallel-heic/package/HyperDR-1.0.0-windows-x64.zip`.
It is 18,986,793 bytes versus 18,966,345 bytes for the preceding export-optimization
package: +20,448 bytes (+0.108%). No GPU runtime or other dependency was added.
