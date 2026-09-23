# Command-line reference

Every command, option, exit code, and per-encoding behaviour of the `HyperDR`
executable. For the project overview and build instructions see
[README.md](../README.md); for the rendering contract see
[rendering.md](rendering.md).

## Usage

```text
HyperDR convert <file-or-directory> --output <directory>
    [--recursive] [--encoding adaptive|ultrahdr|pq|hlg|avif-pq|avif-hlg]
    [--look photographic]
    [--contrast <0.80..1.35>] [--vibrance <-0.50..0.50>] [--pop <0..1>]
    [--headroom-max <0..4>] [--exposure auto|<EV>]
    [--exposure-bias <-2..2>]
    [--headroom auto|<stops>] [--gain-strength <0..2>]
    [--expansion-start <0.18..0.75>] [--area-coverage <0..1>]
    [--highlight-recovery blend|reconstruct|clip|unclip]
    [--quality <0..100>] [--depth <8|10>] [--hevc-preset slow|medium]
    [--preview-max-edge <pixels>] [--fast-preview] [--decode-cache <dir>]
    [--ai-model <id>] [--ai-brightness <EV>] [--ai-contrast <slope>]
    [--ai-shadows <EV>] [--ai-highlights <stops>]
    [--ai-hdr-range <stops>] [--ai-expansion-start <0..1>]
    [--no-verify] [--overwrite|--skip-existing] [--report <file.json>]

HyperDR inspect <file.heic> [--json]
HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]
                                    [--reference <source-image>]
HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]
                          [--quality <1..100>] [--half-size]
                          [--highlight-recovery blend|reconstruct|clip|unclip]
HyperDR preview-frame <image> --output <preview.hpf> [look options]
                          [--preview-max-edge <pixels>] [--fast-preview]
HyperDR model-gain <image> --ai-model <id> [AI post options]
                          [--input-tensor <linear-p3.f32> --tensor-width <px>
                           --tensor-height <px> [--capture-json <capture.json>]]
HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>
                          [--long-side <pixels>] [--half-size] [look options]
HyperDR model-list [--json]
HyperDR curve [look options] [--samples <N>]
HyperDR schema
```

Every setting above is declared once in the converter's C++ table. `--help`, the
command-line parser, the resume fingerprint and the report's settings block are
all generated from it, so those converter surfaces cannot drift apart.

`schema` prints that table as JSON: each setting's key, flag, type, range or
choices, default, whether it can change the encoded bytes, and its help text.
`schema/settings.json` is that generated output, checked in for the panel
backend and contract checks. The browser panel has a separate UI schema for
labels, widgets and request mapping, so update that adapter too when a setting
is exposed in the browser.
Regenerate it whenever a setting changes:

```powershell
HyperDR schema > schema\settings.json
```

## Exit codes

HyperDR uses stable process exit codes so scripts can distinguish invalid usage
from a completed conversion that contains file failures:

| Code | Meaning |
| --- | --- |
| `0` | The command completed successfully. For `convert`, every discovered file succeeded. |
| `1` | The command ran, but conversion or structural verification failed. |
| `2` | Invalid command line, missing arguments, unavailable input, or another fatal exception. Invoking HyperDR with no command also returns `2`; `--help` returns `0`. |

Diagnostics and per-file status are written to stderr. Machine consumers should
use `--report` for conversion results rather than parse those human-readable
lines.

`curve` prints the exporter's own global tone curve as JSON for diagnostics and
regression tests. The browser preview does not reimplement that curve: C++
produces the photographic SDR base, real gain map, and reconstructed HDR plane,
then sends both planes as linear Display-P3 float32 data.

## Input handling

Input discovery is case-insensitive and accepts the common LibRaw RAW
extensions (including `.arw`, `.cr2`, `.cr3`, `.dng`, `.nef`, `.raf`, `.orf`,
`.rw2`, and `.pef`), plus `.jpg`, `.jpeg`, `.png`, `.heic`, `.heif`, and
`.avif`. RAW files retain the RAW highlight recovery controls; every other
input is normalized into the same linear Display-P3 processing space, HDR ones
included -- diffuse white sits at 1.0 and the highlights above it are kept
rather than clipped.

The browser panel requests `HyperDR preview-frame`, whose packet contains the
photographic SDR base, the real gain map, and reconstructed HDR as linear
Display-P3 float32 planes. The browser only presents those planes; it no longer
compresses HDR into an 8-bit JPEG and then tries to recreate the exporter's
tone and gain-map maths. When an Ultra HDR source cannot be decoded through the
native path, the packet explicitly reports a degraded SDR fallback.

## Embedded AI model

`--ai-model <id>` replaces the mathematical gain field with one of the
embedded native models while retaining the normal SDR development, guided
filter, ISO gain coding, reconstruction, and encoders. The model receives an
in-memory linear Display-P3 thumbnail and returns one signed-log2 gain sample
per stride-16 cell; no Python process or model sidecar is involved.

`model-list --json` reports the ids, versions, capture requirement and fallback
for every option this build carries. `embedded`, and omitting the flag's value,
still select the incumbent; an id the build does not have is an error.
`docs/model-integration.md` describes the table, model 2's capture contract and
the reconstruction offsets.

`model-gain --input-tensor` runs the model on a developed HWC linear-P3 float32
tensor instead of decoding an image, which is how the exported networks are
compared against PyTorch on the same input;
`--capture-json` supplies the six capture settings that accompany it.

The six `--ai-*` controls run after inference. They do not change the model
tensor and are separate from the panel's manual-mode look controls.
`model-gain` exposes the filtered stride-16 grid as a binary stdout packet for
panel/diagnostic use.

Recommended photographic conversion:

```powershell
HyperDR convert photo.ARW --output out --look photographic --depth 10 `
  --contrast 1.08 --vibrance 0.12 --headroom-max 4 --report out\report.json
```

## Encodings

HEIC uses the x265 `slow` preset by default. Add `--hevc-preset medium` to
encode Adaptive HDR, PQ, or HLG HEIC faster, with a small possible change in
file size or fine detail. The panel exposes this as **Fast HEIC export**. RAW
OpenMP parallelism and AVIF multithreading are automatic; neither needs this
option.

Large HEIC exports encode independent 2048-pixel tiles concurrently, then
assemble the HEIF grid in row-major order. This also applies to full-resolution
gain maps and to PQ/HLG exports. Tile coding settings, decoded pixels, and HDR
metadata are preserved; container layout may differ. The default is one tile
worker per four logical CPU cores, capped at four workers, because each x265
encoder also uses internal threads. For diagnostics,
`HYPERDR_HEIC_TILE_WORKERS=1` restores serial encoding; values 2 through 4
override the automatic count. Small images keep the single-image path.

`--encoding avif-pq` and `--encoding avif-hlg` write 10-bit BT.2100 AVIF using
the same reconstructed HDR image, the same Rec.2020 matrix, and the same
transfer functions as the HEIC paths, so they differ only in container and
codec. There is no gain-map AVIF: libavif's support for it is still behind an
experimental build flag, and Adaptive HEIC and Ultra HDR JPEG already cover
that case.

`--encoding adaptive` is the compatibility-first default. `pq` and `hlg` always
write 10-bit HEVC Main10 with Rec.2020 primaries and the matching BT.2100 transfer
function. They also carry computed MaxCLL/MaxFALL metadata. PQ maps diffuse white
to 203 nits and preserves up to the 10,000-nit PQ ceiling. HLG uses the BT.2100
1000-nit system OOTF, placing diffuse white at signal level 0.75; its useful range
above 203-nit white is therefore about 2.3 stops. The OOTF (system gamma 1.2) is
applied to Rec.2020 luminance, as BT.2100 defines it, in both HLG files written
and HLG files read, so a saturated colour keeps its channel ratios; a scene
channel still cannot exceed the signal's maximum, which lets a saturated red
reach only about 77% of the display peak.

`--encoding ultrahdr` writes a backward-compatible `.jpg`/JPEG/R file. Its
primary image is an 8-bit Display P3 SDR rendition and its secondary image is
the project's precomputed single-channel gain map. The file carries both Ultra
HDR v1 XMP and ISO 21496-1 metadata for Android and cross-platform compatibility:

```powershell
HyperDR convert photo.ARW --output out --encoding ultrahdr --depth 8
HyperDR verify out\photo-hyperdr.jpg
```

An HDR input (HLG/PQ HEIC or AVIF, Ultra HDR, Adaptive HDR) is packaged so
both gain-map encodings decode back to its HDR pixels: a full-resolution,
per-pixel gain map, a base derived from the HDR pixels, and a declared headroom
equal to the photograph's own. Use `--depth 10` for its Adaptive HDR base, which
is what the panel sends for an HDR source; an 8-bit base cannot hold a 10-bit
camera's deepest shadows. See [rendering.md](rendering.md#input-domains).

## Verification, resume, and caching

Conversions decode-verify their output by default. For trusted high-volume batch
work, `--no-verify` skips that final self-check; reports then record
`self_verified: false` independently of conversion success.

`verify <output> --reference <source>` additionally decodes both files the way
the converter reads them -- a gain map applied at its full alternate headroom,
PQ/HLG through their exact inverses -- and reports what a viewer would see:
ITU-R BT.2124 ΔE ITP (1.0 ≈ one just-noticeable difference) as mean and
percentiles, the share of pixels above 1, 2 and 5, the mean in shadows
(< 0.18 of diffuse white), midtones and highlights (> 1.0), PSNR over PQ-encoded
BT.2020 RGB, and both luminance peaks. The same figures are repeated on 4×4
linear-light means, which keeps tonal and colour shifts but not the pixel-level
dither grain of an 8-bit base. For a 61 MP Sony HLG 4:2:2 HEIF (9504×6336, a
dark night scene) converted with the panel's HDR-source defaults at quality 90:

| Output | ΔE ITP mean (1:1 / ¼ scale) | highlights (1:1) | PSNR (1:1) | peak |
| --- | --- | --- | --- | --- |
| Adaptive HDR, 10-bit base | 2.13 / 0.77 | 4.07 | 47.8 dB | 2.30 stops, exact |
| Ultra HDR | 4.81 / 2.12 | 4.63 | 40.6 dB | 2.30 stops, exact |
| For scale: the same frame re-encoded as 10-bit HLG | 1.49 / 0.62 | 4.57 | 54.3 dB | 2.30 stops |

Ultra HDR's remaining difference is concentrated below about 2 cd/m², where its
8-bit JPEG base is coarser than the camera's 10-bit HLG.

```powershell
HyperDR verify out\DSC02120-hyperdr.heic --reference DSC02120.HIF
```

`--skip-existing` makes interrupted recursive batches resumable. After each
successful conversion HyperDR records a fingerprint in a hidden `.hyperdr/`
folder mirroring the output tree: the input's size, modification time, and
SHA-256 digest, plus a hash of every setting that can change the encoded bytes.
A file is skipped only when all of that — and the output hash — still matches,
so replacing a RAW in place cannot silently keep the previous render. An output
with no recorded provenance is always treated as stale.

The fingerprint comes from the settings table rather than a hand-maintained
subset, and options that cannot change the bytes (`--no-verify`, `--report`,
`--overwrite`) are excluded, so toggling them never forces needless work. One
consequence of covering every setting: sidecars written by earlier builds no
longer match, so the first batch after an upgrade re-renders once and every
batch after that skips normally.

`--decode-cache <dir>` stores the decoded, bounded linear image so that runs
differing only in look controls can skip the RAW decode entirely. The browser
panel enables this automatically for native previews; moving a look slider
reuses the half-size, resampled linear RAW instead of entering LibRaw again.

## Look controls

The GUI separates whole-image brightness, **HDR brightness headroom**, and
**tone-region coverage**. The panel starts whole-image brightness at +0.6 EV
and ranges from 0..+2 EV; it is applied after exposure selection to both the SDR
base and HDR rendition. The panel resets all image-scoped adjustments whenever
a new photo is opened. An HDR photograph instead opens as itself: brightness
0 EV, HDR strength 1 and the format's full range, which leaves its highlights
exactly as the file declares them, and 重置 returns it there rather than to an
SDR rendering. The standalone CLI remains neutral at 0 EV unless
`--exposure-bias` is supplied.
`--exposure auto` is honoured for RAW only. With an external DCP, auto uses
the profile baseline instead of the photographic scene-exposure estimate;
see [RAW camera profiles](#raw-camera-profiles). A JPEG, PNG or HDR input is already
a finished photograph, so automatic exposure would re-measure someone else's
grade; a manual `--exposure <EV>` is still applied to them. See
[rendering.md](rendering.md#input-domains). The other primary controls are photographic
expansion strength (`--gain-strength`, effective range 0..1; the CLI accepts up
to 2 for external gain maps) and expansion range (`--headroom`, a direct target:
Adaptive 0..3, Ultra HDR/PQ 0..4, HLG 0..2.3 stops).
The expansion region has its own section: expansion start (`--expansion-start`)
and local-to-diffuse area coverage (`--area-coverage`). **Advanced** exposes
contrast, vibrance, highlight recovery and encode quality; the renderer itself
is not selectable there, and the panel always runs `--look photographic`.
Shadows remain protected by the shoulder invariant and noise guard. The strength
knob also drives `--pop` so the export carries the same iPhone-style EDR punch as
the panel's live preview, which shows a broad, vivid highlight expansion with a
WebGPU true-HDR path and a luminance/RGB histogram plus highlight/shadow clipping
readouts. That preview decodes the source the same way the export does — a RAW
goes through LibRaw at half size rather than through the camera's embedded JPEG —
so `--highlight-recovery` is visible before you convert. The panel is a light,
image-forward layout; see [apps/panel/README.md](../apps/panel/README.md).

`photographic` is the default. Its defaults are contrast `1.08`, vibrance `0.12`,
and automatic headroom capped at `4` stops. It uses validated EXIF ISO, shutter,
and aperture when all are present; absent or invalid fields are not fabricated.
For a low-light capture, its middle-grey target falls toward `0.10` and positive
automatic exposure is capped at `+1.5 EV`.

`--pop <0..1>` (default `0`) boosts EDR strength: it raises the diffuse gain
floor, lets auto-headroom reach a little higher, and keeps more colour in bright
highlights. A soft eligibility taper allows a small, bounded transition around
the shoulder instead of erasing highlight edges.

A manual `--headroom` must be within `0..--headroom-max`; validation happens
before RAW decoding. `--gain-strength` can attenuate local HDR gain. The
photographic renderer caps values above `1` at the global curve target so its
output cannot exceed that target; external gain maps retain the documented
`0..2` scale for controlled amplification.

## Creative colour LUT and SDR output

Use `--encoding sdr-jpeg` for an ordinary 8-bit sRGB JPEG with no HDR or gain map.
`--lut <file.cube>`, `--lut-input`, `--lut-output`, and `--lut-strength <0..1>`
configure creative grading. The default spaces are sRGB; `rec709` means Rec.709
primaries with display gamma 2.4. RAW sensor calibration remains the separate
`--raw-linearization-lut` option. See the [LUT pipeline guide](color-lut-pipeline.md).


## RAW camera profiles

`--raw-profile <file.dcp>` selects an external camera DCP for RAW development.
Omitting it preserves the existing native RAW development. For example:

```powershell
HyperDR convert DSC01925.ARW --output output --encoding sdr-jpeg --raw-profile "C:/Program Files/Adobe/Adobe Lightroom Classic/Resources/CameraProfiles/Adobe Standard/Sony ILCE-7RM5 Adobe Standard.dcp"
```

The same option applies to `preview-frame`, `thumbnail`, `model-input` and
`model-gain`. It participates in decode, preview, model and output identities;
replacing the profile's contents invalidates its cached result. The decoder
checks the profile's camera model against the RAW and reports invalid,
unreadable or incompatible profiles as errors.

The supported traditional RGB DCP pipeline applies camera matrices,
HueSatMap/LookTable, baseline exposure, black rendering and the profile's tone
curve. A missing profile curve uses the Adobe SDK ACR3 default. This follows
SDK-style development and is an approximation of the corresponding Lightroom
look, not an exact implementation of Lightroom's current Process Version.
`--exposure auto` uses the RAW baseline plus DCP BaselineExposureOffset, once;
manual exposure and `--exposure-bias` remain additional adjustments. HDR
expansion is HyperDR's rendering of the selected SDR base.
The DCP CLI defaults to neutral contrast (1) and vibrance (0); explicitly
requested values apply after development. `pop` affects HDR expansion only.
Native RAW formats may lack Adobe's camera baseline exposure; a DCP alone
cannot recover that value. See the [A7R V validation](raw-dcp-validation.md)
for the measured difference and an explicit exposure adjustment.

In the panel, open a RAW and use **RAW camera profile** above **Processing mode**.
This section is hidden and disabled for non-RAW input. Choose **HyperDR default**,
any matching DCP discovered in local Lightroom/Adobe camera-profile directories,
or **Import DCP…**. The list includes all matching camera styles, deduplicated
and sorted with Adobe Standard and Camera ST first.
Automatic discovery requires readable camera make/model
metadata; other RAW containers can use a manually selected DCP. Profiles come
from the user's installation or upload and are not distributed with HyperDR.
The panel stores an immutable copy with the photo, restores the selection with
its session, and refreshes the original comparison and AI/ordinary previews
when it changes. The first switch from HyperDR default to DCP sets the panel's
brightness adjustment to 0 EV; subsequent profile switches preserve edits.

Creative display-space LUTs can follow DCP development. A scene-space
`--lut-input slog3-sgamut3cine` LUT and `--raw-profile` are mutually exclusive:
the DCP result already has its base tone rendering and is not a scene Log input.
