# HEIF input diagnostics

These tools are excluded from the default build and require the codec/test configuration:

```sh
cmake --build build --target heif_input_probe heif_input_metrics
build/heif_input_probe --self-test
build/heif_input_probe INPUT.heic build-p3b/bilinear
build/heif_input_probe INPUT.heic build-p3b/nearest --nearest-chroma --integer-rgb
build/heif_input_probe INPUT.heic build-p3b/rounded --rounded-chroma --integer-rgb
build/heif_input_metrics BEFORE.f32 AFTER.f32 WIDTH HEIGHT BIT_DEPTH
```

The output directories contain headerless float32, interleaved, oriented linear
Display P3 (`linear_p3.f32`, and `authored_sdr.f32` for a gain-map input), plus
`metadata.json`. `--metadata-only` omits pixel dumps. Peak physical footprint and
decode time exclude writing the dumps. The diagnostic object has extra per-pixel
mode checks; measure G8 with the normal product library, not this executable. Use separate `TMPDIR`s for concurrent runs.

`--nearest-chroma` changes only chroma interpolation. `--rounded-chroma` keeps
bilinear interpolation and rounds its result to an integer chroma code before
the RGB matrix. All decoding, colour conversion, transforms, reconstruction and
metadata handling remain the same. These two flags are mutually exclusive. `--integer-rgb` independently clips and
quantizes encoded RGB to the source bit depth, reproducing the old input boundary
for attribution. The default preserves unclipped floating RGB through the colour
pipeline. All three switches exist
only in a separately compiled YUV conversion object in this executable; the codec
library and app have neither the switches nor their state.

Compare each diagnostic mode with the same pre-switch baseline. A nearest-neighbour
exception requires that the nearest diagnostic pass the original G3 limits,
including the authored SDR plane when present. Lead approved the Sony 4:2:2 rounded-chroma exception on 2026-10-19 after
its diagnostic met the original limits; retain the three-mode evidence in the
batch report. These attribution modes never change the product path.
The encoded-domain p99 metric assumes the sRGB transfer used by SDR P3; use
PSNR-PQ, delta ITP and mean luminance for HDR. The ITP percentile uses the engine's
0.01-wide histogram upper bound; its open last bin returns the maximum.

Private originals must stay read-only and outside the repository. Put their
full-resolution derived files under `build-*/`, retain only metadata, metrics and
SHA-256 evidence after comparison, and delete the pixel dumps.
