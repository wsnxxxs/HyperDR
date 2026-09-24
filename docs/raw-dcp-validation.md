# RAW DCP implementation and validation

Validated on 2026-09-21 with LibRaw 0.22.1, the provided Sony ILCE-7RM5
`DSC01925.ARW`, and Lightroom 15.4.1 / Process Version 15.4 reference TIFFs.
Implementation follows [the design](raw-dcp-compatibility-plan.md).

## Implemented

- Traditional three-channel DCP reader: ColorMatrix/ForwardMatrix,
  dual-illuminant interpolation at the as-shot white, HueSatMap, LookTable
  (linear and sRGB value encoding), ToneCurve, BaselineExposureOffset and
  DefaultBlackRender. Missing tone curves use Adobe SDK's ACR3 curve.
- Separate scene-linear decode and DCP SDR development, followed by optional
  contrast/vibrance, display LUT and HyperDR HDR expansion. The native default
  remains available. Scene S-Log3 LUTs and DCP are alternative developers.
- CLI `--raw-profile`; panel discovery of all matching installed camera DCPs,
  manual DCP import and session persistence. The RAW-only profile section sits
  above processing mode. The tested A7R V installation supplies 10 profiles.
- Profile SHA-256 in decode/model/output identities, cache restoration,
  report schema 11 and external model binding. DCP data is not bundled.

## Actual sample

### 2026-09-24 additions

Static XMP profiles can now add an embedded HSV LookTable and composite PV2012
curve after DCP development. The local Adobe Color profile was successfully read
with the Sony ILCE-7RM5 Adobe Standard DCP. This proves file compatibility;
it does not establish visual equivalence with Lightroom. Adaptive profiles and
unsupported rendering properties are rejected.

DCP HDR rendering also retains pre-tone scene luminance above diffuse white,
using the same baseline/profile/user exposure once. Color is inherited from
the SDR development; clipped chroma cannot be reconstructed. SDR rendering is
unchanged with no XMP selected. Unit tests cover HDR highlight ordering,
strength-zero identity, and continuity at diffuse white.

Local integration checks on the same A7R V photograph:

- Adobe Color plus Adobe Standard produced a 1280-pixel fit preview.
- A resident worker produced a 400×300 full-resolution ROI in 6.34 seconds;
  a subsequent pan took 4.24 seconds and reused the decoded source. Overlapping
  pixels were identical. These are single-run diagnostics, not a speed guarantee.
- Synthetic detail crops exactly matched the corresponding full-render pixels;
  the API rejected regions larger than 2048 pixels per side.
- Direct CLI and resident-worker previews passed with Chinese RAW, DCP, XMP,
  and output paths after unifying the Windows argument boundary as UTF-8.
- The 9504×6336 ProPhoto reference TIFF exported and verified at its original
  dimensions as 16-bit Display P3 TIFF. Report timings were 7.10 s decode,
  0.94 s rendering, 11.73 s codec, and 6.84 s verification. This converts the
  color space; it is not a byte-preserving ProPhoto round trip.

Detail inspection currently displays SDR and still renders the full photograph
before cropping, so panning can take seconds. A browser was unavailable for
visual validation in this run. GPU processing and piecewise LCP vignetting
remain separate follow-up work; neither is claimed by this implementation.

Reference TIFFs are 9504 × 6336, 16-bit ProPhoto RGB. Measurements use their
embedded ICC matrix/TRC and XYZ D50; HyperDR uses the float linear P3 SDR
preview plane, Bradford-adapted to D50. Sky ROI: x=[0.20,0.75),
y=[0.08,0.26). This is a regional diagnostic, not a whole-image pixelwise
Delta E score. Previews use half-size demosaic and a 1440-pixel long edge.

| Development | Sky median Y | Sky C*ab |
| --- | ---: | ---: |
| Lightroom Adobe Standard | 0.15943 | 24.58 |
| Lightroom Camera ST | 0.14781 | 28.83 |
| HyperDR native default | 0.23658 | 25.66 |
| HyperDR Adobe Standard DCP, 0 EV | 0.11129 | 22.84 |
| HyperDR Camera ST DCP, 0 EV | 0.10554 | 28.24 |
| HyperDR Adobe Standard DCP, +0.35 EV | 0.15232 | 25.04 |
| HyperDR Camera ST DCP, +0.35 EV | 0.14790 | 28.74 |

For this sample, **+0.35 EV** is a useful manual starting point, especially
for Camera ST. It is not a universal camera calibration and is not hardcoded.
LibRaw supplies no valid BaselineExposure for this native ARW (`-999` is its
missing-value sentinel); HyperDR treats it as zero. The DCP's own Camera ST
offset of -0.35 EV still applies exactly once. Adobe's camera baseline and
current Process Version rendering are not fully specified by the DCP.
Residual differences include demosaic, noise reduction, lens corrections,
black rendering and highlight handling; exact Lightroom reproduction is not
claimed.

Profile identities from the user's Adobe installation:

- Adobe Standard: `91455edee12a62710aeb57a6363f7507df13a793978fe98003593308a922015b`
- Camera ST: `e6b8c47fe5221a64a62516ab8215f49c9edf8faf6380679af65a30cc212704c9`

Example (PowerShell; substitute the profile path as needed):

```powershell
build-release/Release/HyperDR.exe preview-frame raw处理管线相关图片/DSC01925.ARW --output output/camera-st.hpf --raw-profile "C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/CameraProfiles/Camera/Sony ILCE-7RM5/Sony ILCE-7RM5 Camera ST.dcp" --exposure 0.35 --preview-max-edge 1440 --fast-preview
```

## Checks

- Release build and all 43 native CTest cases passed, including DCP parsing,
  matrices, HSV interpolation/encoding, tone/exposure, creative controls and
  profile cache mutation.
- Python suite: 211 cases, with one optional skip; a newly added string setting
  initially exposed a stale contract whitelist, which was corrected and its
  37-case contract suite rerun successfully.
- Actual native-default preview is byte-identical to the pre-change baseline;
  Camera ST cache hit is byte-identical to uncached development.
- Full RAW demosaic to a size-limited 1440-pixel Ultra HDR JPEG succeeded with
  encoder self-verification. Report records DCP name/hash and -0.35 EV offset.
- `model-input` emits `raw-dcp-v1`, the profile hash, neutral creative controls
  and the correct baseline. Browser import/discovery/profile switching and
  colour-only mode were checked with the actual ARW; no console errors.

Local generated evidence is under ignored `output/dcp-implementation/`.
