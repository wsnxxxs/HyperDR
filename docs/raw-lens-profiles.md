# Lightroom lens profiles

HyperDR discovers locally installed Lightroom and Camera Raw `.lcp` files for
RAW photographs. The RAW camera-profile section shows an enabled checkbox and
the matched lens profile directly below the DCP selector. Correction is enabled
by default when a compatible profile is available; the checkbox disables it for
the current photograph. Non-RAW inputs do not use LCP profiles.

Discovery reads camera make/model and lens identity through LibRaw without
unpacking pixels, with standard TIFF/EXIF fallback. It accepts RAW profiles with
matching lens names and compatible camera metadata. Unmatched or missing lens
metadata leaves correction disabled. Matched profiles are copied into the
session by content hash, so preview and export use the same file.

The current implementation supports perspective v2 distortion (radial and
tangential) and linear-light vignette correction, interpolated by focal length
and aperture. Duplicate focal/aperture records use the lowest residual error
for distortion and vignetting independently. With no reliable capture focus
distance, equal fits prefer the more distant calibration, then a stable ordering
of coefficients; XML record order never selects the correction. This fallback
does not reproduce focus-specific calibration. Calibration coordinates account
for camera orientation. Automatic
scaling fills the output without black borders while preserving its pixel
size. Geometry uses Catmull-Rom interpolation bounded by the source neighbourhood
to retain detail without overshoot; a vignette-only calibration operates in place
without resampling. Existing DNG gain maps or an explicit shading map suppress the additional
LCP vignette correction. Fisheye and chromatic-aberration models are not applied;
this is not intended to reproduce every Lightroom rendering decision.

An explicit shading map is additional calibration after the embedded DNG gain
map, not a replacement for it. For a calibrated DNG, supply residual gains;
repeating its original optical correction would apply that correction twice.
Both forms suppress LCP vignetting while retaining LCP geometry correction.

Preview, AI model input, original comparison, and export share the correction
option. Changing it invalidates decoded and inferred results. Export reports
record the applied correction and profile path; external model bindings include
the profile content hash to reject stale gains.

The native preview worker retains one half-size RAW decode and derives its draft
and final preview sizes from that image. Size-specific disk caches remain in use;
the large intermediate is kept only in the worker, not written to disk. Full
exports still decode at full resolution. See the
[pipeline review and measurements](image-pipeline-review-2026-09-21.md).

The command-line equivalent is:

```powershell
HyperDR convert photo.arw --output result --raw-lens-profile lens.lcp
HyperDR raw-metadata photo.arw
```

The profile files remain user-owned Adobe installation assets and are not
bundled with HyperDR.
