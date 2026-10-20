# JPEG system-decoder boundary (P7-0)

Measured on macOS 27.0.1 / Apple Silicon. This is a decoder investigation, not a
new render tolerance. The input is the same read-only 4096 × 3072 JPEG used by
AE-3. No input photographs or derived images are included here.

`JPEGDecode.mm` is a standalone macOS diagnostic, outside the Swift targets.
Link Foundation, CoreImage, CoreGraphics and ImageIO plus the existing build's
libjpeg-turbo and lcms2 static libraries. Run it with one JPEG path. It prints
only aggregate numbers. All component and control JPEGs stay in memory.

The comparison is factored as follows:

1. Decode once with libjpeg-turbo's production defaults (ISLOW, fancy upsampling).
   Send those **same RGB bytes and same embedded ICC** to both lcms2 (the previous
   engine's relative-colorimetric transform to linear P3) and CI (RGBAf linear P3).
   This isolates ICC/color conversion from the JPEG decoder.
2. Send the same decoded RGB through CI, and compare it with the system JPEG
   decoded through CI. Both ends now have the same CI color conversion.
3. Disable CI color management on both input and output to inspect the decoded
   JPEG code values directly. Compare fancy versus nearest-neighbor libjpeg
   upsampling. Separately compare CGContext's 8-bit path: that path has a
   different quality policy and must not be used as a proxy for CI decoding.
4. Extract each original component's **unchanged quantized DCT blocks and
   quantization table** into a grayscale JPEG. Comparing these isolates IDCT
   without ICC, chroma upsampling, or YCbCr-to-RGB conversion. Reconstruct the
   separately decoded Y/Cb/Cr planes with an explicit CPU bilinear sampler and
   BT.601 full-range matrix as an additional interpolation/rounding control.
5. Encode RGB 4:4:4, grayscale, and neutral-chroma 4:2:0 controls from the decoded
   input. These controls have different compressed coefficients from the
   original; they identify which steps are present, not an additive per-pixel
   error budget for the original file.

10-bit comparisons use the same clipped P3/sRGB OETF as AE-3 (linear values
clipped to [0, 1] before encoding). Native-code comparisons are in 8-bit code
units. Maxima and percentiles from different controls cannot be added together.

| Isolated comparison | Unit | Maximum | p99.9 |
|---|---|---:|---:|
| Same RGB + ICC: lcms2 vs CI | 10-bit P3 code | 0.03591 | 0.01785 |
| Same CI conversion: turbo RGB vs system JPEG | 10-bit P3 code | 14.4732 | 7.38285 |
| Full old transform vs system pipeline | 10-bit P3 code | 14.4778 | 7.38211 |
| Original Y / Cb / Cr IDCT, each component separately | 8-bit native code | 1 / 1 / 1 | 1 / 1 / 1 |
| System component IDCT + CPU bilinear/matrix vs CI | 8-bit native code | 0.70506 | 0.51626 |
| Turbo component IDCT + CPU bilinear/matrix vs CI | 8-bit native code | 2.60937 | 1.20480 |
| Turbo production decode vs unmanaged CI | 8-bit native code | 3.60718 | 1.84027 |
| Turbo nearest decode vs unmanaged CI | 8-bit native code | 33.9509 | 8.83629 |
| 4:4:4 turbo decode vs unmanaged CI (no chroma upsampling) | 8-bit native code | 3.63347 | 1.88408 |
| Neutral 4:2:0 turbo vs CGContext | 8-bit native code | 1 | 1 |

**Conclusion.** AE-3's approximately 14-code discrepancy is reproducible entirely
before our processing graph: decoding RGB bytes with libjpeg-turbo and then using
CI's color conversion still differs from system JPEG decoding by 14.4732 10-bit
codes. ICC conversion contributes only 0.03591 10-bit codes on identical source
RGB. Unchanged original DCT coefficients show up to one 8-bit code of IDCT
rounding difference in **each** Y/Cb/Cr plane; color reconstruction can amplify
these independent differences. Once the **system's** component IDCT values are
shared, explicit CPU bilinear chroma interpolation plus the full-range YCbCr
matrix agrees with CI within 0.70506 8-bit codes. Thus residual chroma/matrix
arithmetic is sub-code, and this is not a different nearest-vs-fancy chroma
sampling family: nearest gives 33.9509 codes of error, whereas production fancy
gives 3.60718. The 4:4:4 control still has 3.63347 codes without any chroma
upsampling, confirming that IDCT and intermediate/output rounding account for
most of this decoder boundary. These controls do not expose Apple's private
arithmetic, so the 0.70506 residual is a combined interpolation/matrix bound,
not a claim to separate their exact internal contributions. It is inappropriate
to add maxima at different pixels to obtain 14. The new system decode is the
source of truth; processing-node accuracy continues to use the original
one-code requirement on a **shared decoded source**. No compensating color
matrix, sharpening or decoder-specific correction belongs in the graph.

The plain CGContext 8-bit draw path merits a separate note: turbo's nearest
output agrees with it to 3 codes, while fancy differs by 34. That does **not**
describe the CI path, whose nearest comparison is much worse. Inferring CI's
JPEG quality policy from a CGContext bitmap would have produced the wrong
conclusion. CI rendering of a CGImage and direct CI JPEG loading agree at this
boundary (both approximately 14.478 total 10-bit codes from the old pipeline).
