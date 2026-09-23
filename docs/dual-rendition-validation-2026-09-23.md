# Dual-rendition validation — 2026-09-23

Gain-map inputs now retain the authored SDR image alongside reconstructed HDR.
Rendering, preview resizing, orientation and decode caching carry both images.
Single-version HDR uses the fixed 0.48 SDR knee and a diffuse-white HDR knee
when the remaining range is at least one stop.

## Reproduction

Run the codec-enabled Release build and the portable regression script:

```powershell
cmake --build build-release --config Release --parallel 6
ctest --test-dir build-release -C Release --output-on-failure
python scripts/validate_rendition_roundtrip.py --executable build-release/Release/HyperDR.exe --raw raw处理管线相关图片/DSC01925.ARW --authored output/dual-rendition-validation/IMG_0017.heic --authored output/dual-rendition-validation/IMG_0707.heic
```

The script generates a neutral SDR ramp and seven encoded input fixtures:
Adaptive, Ultra HDR, PQ HEIC, HLG HEIC, PQ AVIF, HLG AVIF and SDR JPEG.
It exports each to both gain-map formats and compares the decoded SDR and HDR
against the input's rendered endpoints. It also checks first-generation SDR/RAW
exports, second-generation RAW gain-map inputs and the two supplied Apple photos.
This is 26 paired checks with the optional fixtures above. Single-version
formats first generate their missing rendition; the test does not assert they
can retain a second image they never contained.

The image checks use a 256-pixel preview edge and quality 100, with a 5% mean
luminance-ratio tolerance and 10% relative RGB MAE tolerance for each rendition.
The native rendering tests separately check exact unadjusted float endpoints,
zero and fractional strength, unequal offsets, diffuse white, and packaging
quantization. Private originals and generated images remain outside Git.

## Named acceptance checks

The 60,217,344-pixel `DSC02120.HIF` was exported to Adaptive HEIC at quality 90,
10-bit base, neutral contrast/vibrance/pop and three-stop output allowance.
Both runs use the existing `verify --reference` fidelity measurements.

| Metric | Existing baseline | Updated export |
| --- | ---: | ---: |
| Mean ΔE ITP | 2.129 | 2.116 |
| Highlight mean ΔE ITP | 4.069 | 4.045 |
| Quarter-size mean ΔE ITP | 0.771 | 0.758 |
| HDR peak, relative to diffuse white | 4.926 | 4.926 |

At the regression preview size, `IMG_0017` SDR mean luminance after re-export is
0.99983× its authored base through Adaptive and 1.00002× through Ultra HDR.
Legacy Apple `IMG_0707` now reports `dual-rendition`, with successful SDR/HDR
round trips. First-generation RAW→Ultra HDR SDR mean luminance is 0.99588× the
rendered RAW SDR endpoint; the previous 7–23% darkening is absent in this check.

An odd-size 193-pixel-edge `IMG_0017` preview produces byte-identical two-plane
packets on cache miss and cache hit. The cache schema was incremented to reject
older entries that cannot contain the authored base.

Detailed generated evidence is under `output/dual-rendition-validation/`,
including `baseline-verify.txt`, `hif-verify.txt`, and `roundtrip/summary.json`.

## Representation limits

- The extra RGB float plane costs 12 bytes per pixel, about 576 MB at 48 MP.
  Batch export releases both decoded source planes before encoding.
- RGB gain maps can preserve channel-dependent endpoints in Ultra HDR, subject
  to gain quantization and JPEG loss. Apple-compatible Adaptive is monochrome;
  incompatible endpoints preserve HDR by changing the SDR base, with
  `render.adaptive_chroma_loss` in the report.
- HLG/PQ LUTs regenerate SDR from graded HDR. SDR-space LUTs retain the authored
  base as their input and propagate its rendition ratio to HDR.
- The inspected Windows dependency is libavif 1.4.2, which exposes gain-map
  decoding. Unsupported gain-map decoding paths report an explicit degradation.
