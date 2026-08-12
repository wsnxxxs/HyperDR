# HyperDR

`HyperDR` is a C++20 command-line converter for ARW, DNG, JPEG, PNG, HEIC,
HEIF, and AVIF images, developed on Windows. It exports six real HDR
representations: Apple-compatible Adaptive HDR HEIC (a Display P3 SDR base plus
an ISO 21496-1 single-channel gain map), Google Ultra HDR JPEG/R, 10-bit ITU-R
BT.2100 PQ and HLG HEIC, and the same two BT.2100 renditions as 10-bit AVIF. PQ,
HLG and AVIF are rendered from the reconstructed linear HDR image; SDR samples
are never merely relabelled HDR.

**Every encoding HyperDR writes, it also reads.** An HDR photograph given as
*input* keeps its highlight range: an Ultra HDR JPEG is read through its gain
map rather than through its backward-compatible SDR primary, an Adaptive HDR
HEIC through its `tmap` gain map, and a BT.2100 PQ or HLG file -- HEIC or AVIF,
4:2:0, 4:2:2 or 4:4:4, which is what cameras such as Sony's write -- through the
exact inverse of the transfer function this project encodes with. All of them
land in the same linear Display P3 working space as a RAW, so the look controls,
the preview and the six exports behave the same whatever the input was.

Camera, lens and capture settings are read from the input's Exif and carried to
the output. ISO is not merely copied: the gain map weighs local expansion
against sensor noise with it, so a high-ISO HEIC is rendered as the high-ISO
photograph it is.

The `photographic` look uses a photographic toe, a shared linear middle, and a
smooth HDR shoulder. It keeps SDR and HDR identical below the shoulder, puts
qualified highlights into HDR headroom, and applies shared chroma processing
before the two luminance outputs split. It is the only renderer; the earlier
`neutral` one has been removed, and `--look neutral` is now rejected.

The code is organised as seven layered modules under `modules/` — foundation,
image, look, container, gainmap, codec, app — each publishing headers from its own
include root, so the layering is enforced by the build rather than by convention.
Everything below `codec` compiles and tests with nothing but a C++20 compiler,
which is why the dependency-free configuration still runs almost the whole test
suite. For a map of the repository and its single sources of truth, see
[docs/project-structure.md](docs/project-structure.md).

## Repository guide

- [`modules/`](modules/) contains the layered C++ core and command-line app.
- [`apps/panel/`](apps/panel/) contains the Python browser-panel server and its
  web client.
- [`HyperDR_Model/`](HyperDR_Model/) contains the optional ML training and
  inference project.
- [`tests/`](tests/) contains cross-component Python, JavaScript, and PowerShell
  tests; module-local C++ tests stay beside their modules.
- [`docs/`](docs/) contains architecture and integration guides, while
  [`scripts/`](scripts/) and [`packaging/`](packaging/) contain development,
  Windows setup, and release tooling.

Generated build trees, release archives, caches, local model reports, and
temporary diagnostics are intentionally not part of the source tree. See the
[project structure guide](docs/project-structure.md) for ownership and cleanup
conventions.

## Quick start

For a packaged Windows release:

1. Extract the ZIP to a writable directory. Any location works; nothing is
   stored next to the program.
2. Install Python 3.11 or newer if you want the browser panel.
3. Double-click `Setup-HTTPS.bat` once if you want the iPhone HDR preview; it
   issues a certificate authority unique to this computer and prints the two
   iPhone trust steps.
4. Double-click `Start.bat`, or run `bin\HyperDR.exe --help` for command-line use.

The release process converts and self-verifies a generated test image in all six
output encodings after extracting the archive. See
[packaging/INSTALL.md](packaging/INSTALL.md) for installation, LAN, and runtime
details, or [packaging/README.md](packaging/README.md) to build a release.

To build from source, use the instructions below.

## Build on Windows

Install Visual Studio 2022 Build Tools with **Desktop development with C++**,
CMake, Git, and vcpkg. From a Developer PowerShell:

```powershell
cmake -S . -B build -G Ninja `
  -DCMAKE_TOOLCHAIN_FILE=C:\tools\vcpkg\scripts\buildsystems\vcpkg.cmake `
  -DVCPKG_TARGET_TRIPLET=x64-windows
cmake --build build --config Release
ctest --test-dir build -C Release --output-on-failure
```

Codec-enabled configuration fetches Google's pinned `libultrahdr` v1.4.0
reference codec and builds it alongside the project.

For the dependency-free core only:

```powershell
cmake -S . -B build-core -DHYPERDR_WITH_CODECS=OFF
cmake --build build-core --config Release
ctest --test-dir build-core -C Release --output-on-failure
```

`--depth 8` is the broadly compatible default. Use `--depth 10` for smooth skies
and large gradients when a Main10-capable x265 DLL is installed; the included
`scripts/prepare_x265_multibit.ps1` prepares that runtime.
PQ and HLG require it. Run the script once after the first codec-enabled build:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\prepare_x265_multibit.ps1 `
  -VcpkgRoot C:\tools\vcpkg -BuildDirectory .\build -Configuration Release
```

After that, the CMake post-build hook preserves the Main10 + 8-bit dual runtime
across normal rebuilds.

## Usage

```text
HyperDR convert <file-or-directory> --output <directory>
    [--recursive] [--encoding adaptive|ultrahdr|pq|hlg|avif-pq|avif-hlg]
    [--look photographic]
    [--contrast <0.80..1.35>] [--vibrance <-0.50..0.50>] [--pop <0..1>]
    [--headroom-max <0..4>] [--exposure auto|<EV>]
    [--exposure-bias <0..2>]
    [--headroom auto|<stops>] [--gain-strength <0..2>]
    [--expansion-start <0.18..0.75>] [--area-coverage <0..1>]
    [--highlight-recovery blend|reconstruct|clip|unclip]
    [--quality <0..100>] [--depth <8|10>]
    [--preview-max-edge <pixels>] [--fast-preview] [--decode-cache <dir>]
    [--no-verify] [--overwrite|--skip-existing] [--report <file.json>]

HyperDR inspect <file.heic> [--json]
HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]
HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]
                          [--quality <1..100>] [--half-size]
                          [--highlight-recovery blend|reconstruct|clip|unclip]
HyperDR preview-frame <image> --output <preview.hpf> [look options]
                          [--preview-max-edge <pixels>] [--fast-preview]
HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>
                          [--long-side <pixels>] [--half-size] [look options]
HyperDR curve [look options] [--samples <N>]
HyperDR schema
```

Every setting above is declared once, in one table. `--help`, the command-line
parser, the resume fingerprint and the report's settings block are all generated
from it, so a new setting cannot appear in some of those places and not others.

`schema` prints that table as JSON: each setting's key, flag, type, range or
choices, default, whether it can change the encoded bytes, and its help text.
`schema/settings.json` is that output, checked in, and the browser panel builds its
own validation from it instead of carrying a second copy of the vocabulary.
Regenerate it whenever a setting changes:

```powershell
HyperDR schema > schema\settings.json
```

### Exit codes

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

Input discovery is case-insensitive and accepts `.arw`, `.dng`, `.jpg`,
`.jpeg`, `.png`, `.heic`, `.heif`, and `.avif`. ARW/DNG files retain the RAW
highlight recovery controls; every other input is normalized into the same
linear Display-P3 processing space, HDR ones included -- diffuse white sits at
1.0 and the highlights above it are kept rather than clipped.

The browser panel requests `HyperDR preview-frame`, whose packet contains the
photographic SDR base, the real gain map, and reconstructed HDR as linear
Display-P3 float32 planes. The browser only presents those planes; it no longer
compresses HDR into an 8-bit JPEG and then tries to recreate the exporter's
tone and gain-map maths. When an Ultra HDR source cannot be decoded through the
native path, the packet explicitly reports a degraded SDR fallback.

Recommended photographic conversion:

```powershell
HyperDR convert photo.ARW --output out --look photographic --depth 10 `
  --contrast 1.08 --vibrance 0.12 --headroom-max 4 --report out\report.json
```

`--encoding avif-pq` and `--encoding avif-hlg` write 10-bit BT.2100 AVIF using
the same reconstructed HDR image, the same Rec.2020 matrix, and the same
transfer functions as the HEIC paths, so they differ only in container and
codec. Gain-map AVIF is deliberately not implemented: libavif's support for it
is still behind an experimental build flag, and Adaptive HEIC and Ultra HDR
JPEG already cover the gain-map case.

`--encoding adaptive` is the compatibility-first default. `pq` and `hlg` always
write 10-bit HEVC Main10 with Rec.2020 primaries and the matching BT.2100 transfer
function. They also carry computed MaxCLL/MaxFALL metadata. PQ maps diffuse white
to 203 nits and preserves up to the 10,000-nit PQ ceiling. HLG uses the standard
1000-nit system OOTF, placing diffuse white at signal level 0.75; its useful range
above 203-nit white is therefore about 2.3 stops.

`--encoding ultrahdr` writes a backward-compatible `.jpg`/JPEG/R file. Its
primary image is an 8-bit Display P3 SDR rendition and its secondary image is
the project's precomputed single-channel gain map. The file carries both Ultra
HDR v1 XMP and ISO 21496-1 metadata for Android and cross-platform compatibility:

```powershell
HyperDR convert photo.ARW --output out --encoding ultrahdr --depth 8
HyperDR verify out\photo-hyperdr.jpg
```

Conversions decode-verify their output by default. For trusted high-volume batch
work, `--no-verify` skips that final self-check; reports then record
`self_verified: false` independently of conversion success.

`--skip-existing` makes interrupted recursive batches resumable. It compares a
fingerprint, not a timestamp: after each successful conversion HyperDR records
the input's size, modification time, and SHA-256 content digest together with a
hash of every setting that can change the encoded bytes, in a hidden `.hyperdr/`
folder mirroring the output tree. A file is skipped only when the input content,
metadata, settings, and output hash still match, so replacing a RAW in place
cannot silently keep the previous render. An output with no recorded provenance
is always treated as stale. Options that cannot change the bytes -- `--no-verify`,
`--report`, and `--overwrite` -- are excluded from the fingerprint, so toggling
them does not force needless work. The fingerprint is derived from the settings
table, so it covers every setting rather than a hand-maintained subset; sidecars
written by earlier builds no longer match, which means the first resumed batch
after upgrading re-renders once and every batch after that skips normally.

`--decode-cache <dir>` stores the decoded, bounded linear image so that manual
CLI runs differing only in look controls can skip the RAW decode entirely.

The GUI separates whole-image brightness, **HDR brightness headroom**, and
**tone-region coverage**. Overall brightness defaults to +1 EV and ranges from
0..+2 EV in both the UI and `--exposure-bias`; it is applied after exposure selection to
both the SDR base and HDR rendition. The other primary controls are expansion strength (`--gain-strength`, 0..1), expansion
range (`--headroom`, a direct target: Adaptive 0..3, Ultra HDR/PQ 0..4, HLG 0..2.3 stops).
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
so `--highlight-recovery` is visible before you convert. The panel is a light, image-forward layout;
see `apps/panel/README.md`.

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
before RAW decoding. `--gain-strength` can attenuate local HDR gain; values
above `1` are capped at the global curve target so output cannot exceed it.

## Rendering and compatibility guarantees

- The photographic path uses a shared toe and middle segment for SDR and HDR.
  Their exponential shoulders asymptote to `1` and `2^headroom_stops` rather
  than hard-clipping highlights.
- A single-channel gain map can only reconstruct a common RGB multiplier. Shared
  vibrance, highlight-to-white convergence, and hue-preserving gamut compression
  therefore happen before the SDR/HDR luminance split.
- Gain maps write zero base and alternate offsets, preserving common RGB ratios
  during ISO 21496-1 reconstruction.
- Gain-map gamma is chosen by simulating 8-bit encode/decode error. Stored values
  use `pow(q, gamma)` and decoders use `pow(code, 1/gamma)`.
- `2^headroom_stops` is the nominal global-curve target. Local highlight
  weighting can deliberately make the final rendered peak lower; the report
  records both values.
- Any gain-grid node that would bilinearly influence an SDR-only pixel is set to
  zero before encoding. The 8-bit auxiliary gain image is HEVC-lossless, so zero
  gain cells survive Adaptive HEIC decoding exactly. Ultra HDR stores the map as
  a grayscale JPEG at quality 85 or higher, as recommended for JPEG/R; the
  requested quality still controls the SDR base.
- RAW is decoded through LibRaw's linear ProPhoto output (`output_color` 4), then
  transformed in float to linear Display P3. ProPhoto is intentional: XYZ
  (`output_color` 5) can clip neutral highlights in its Z channel before the
  float conversion because that matrix row sums above one. Neither path passes
  through Rec.709/sRGB, and out-of-P3 float components remain available until
  output-specific gamut handling. `render.wide_gamut_fraction` is measured on the decoded, linear-P3
  input before exposure or look processing: among pixels with P3 luminance at least
  `0.02`, it is the fraction outside Rec.709. The report also records its
  numerator, denominator, and threshold.
- RAW calibration is configurable before demosaic. LibRaw applies the metadata
  black level, camera white balance, optional bad-pixel coordinate map
  (`--raw-bad-pixels`), and dark-frame PGM (`--raw-dark-frame`); Phase One's
  metadata linearization/defect correction is enabled explicitly. An external
  dark frame is also the supported fixed-pattern-noise path: row/column bias is
  removed when it is present in that measured frame; no scene-derived
  row/column estimator is enabled by default because it could confuse real
  image gradients with sensor noise.
  A code LUT can be supplied with `--raw-linearization-lut`: its text format is
  `N` followed by `N` samples, either raw code values or normalized `[0,1]`
  values. A lens-shading map can be supplied with `--raw-lens-shading`; its
  format is `width height channels` followed by row-major gains, with 1, 3
  (RGB), or 4 (R,G1,B,G2) channels. The opt-in `--raw-auto-bad-pixels` detector
  only replaces extreme zero/saturated outliers with same-CFA neighbours, so a
  supplied calibration map remains preferred for scientific work. `--raw-gain`
  is a sensor-domain digital gain and is included in the decode cache and resume
  fingerprint.
- RAW-domain consumers can call `decode_raw_mosaic()` and `pack_bayer()`. The
  former returns black-corrected, white-level-normalized Bayer samples in sensor
  coordinates; the latter produces `H/2 x W/2 x 4` in fixed `R,Gr,Gb,B` order.
  X-Trans and other non-2x2 CFAs are rejected instead of being silently labelled
  RGGB. The normal export path still demosaics through LibRaw because its
  downstream contract is linear Display P3 RGB.
- The SDR base is quantized with deterministic TPDF dithering, suppressing sky and
  gradient banding that the multiplicative gain map would otherwise amplify.
- The HEIF/BMFF item topology, `tmap` payload layout, and structural verifier are
  unchanged. Ultra HDR JPEG/R output uses Google's reference container writer.
  Every output is decoded and semantically verified before publication.

## Report schema 7

`--report` writes schema 7. Its `settings` block is generated from the settings
table, so it records every setting by its canonical name — not the handful someone
remembered to add — plus `output_depth`, the depth actually encoded (BT.2100 is
always 10-bit regardless of `--depth`). The top-level `raw_processing` block
records the calibration files, auto bad-pixel mode, and sensor digital gain used
for the run. Each file carries flat result fields and `look`, `render`, and
`gain_map` objects. These record EV100 (or
`null`), selected/linear headroom, rendered peak, utilization, gamma, gain
percentiles, high-gain fractions, clipping, and local-weight diagnostics.
The global `settings.pop` and per-file input-domain
`render.wide_gamut_fraction` are also recorded.

Schema 7 retains the compatibility fields `target_*` / `decoded_*` and adds the
unambiguous aliases `requested_crop_*` / `delivered_crop_*`. The latter pair is
the geometry contract used by model sidecars, including odd/CFA-aligned crops.
It also records the per-file sensor raster, DefaultCrop request, actual decoded
dimensions, `decode_degraded`, and `decode_degradation_reasons`. This makes an
unapplied DefaultCrop visible instead of presenting an uncropped result as an
ordinary success; the converter also prints a `warning:` line for each degraded
file, and the panel raises it after a successful run. RAW resolution is not a
degradable export property: previews explicitly request LibRaw's fixed half-size
demosaic, while full exports preserve the input dimensions or fail. RAW inputs
are admitted up to 19008 x 12672 (240.8 MP), the A7R V 16-frame Pixel Shift
composite size.

`sensor_*` is the physical readout and is not rotated by the capture
orientation; `target_*` and `decoded_*` are. Compare `decoded_*` against
`target_*` only when `target_dimensions_applied` is true -- when a recorded
DefaultCrop is rejected, `target_*` is the request that was refused rather than
a geometry the decode delivered. `default_crop_present` distinguishes "no crop
recorded" from "crop applied". `decode_degradation_reasons` is a string array
for diagnostics and display only: new reasons may be added at any time, so no
consumer should branch on its contents.

The machine-readable JSON Schema is
[`schema/report.json`](schema/report.json). It defines every required object,
field, type, enum, and nullable value in a schema-7 report. Update it together
with `modules/app/src/report.cpp` whenever the report version or shape changes.

The flat `files[].headroom_stops` is the actual rendered peak (and is written to
`alternate_headroom`). `render.headroom_stops` and `headroom_linear` are the
selected nominal target; `rendered_peak` and `headroom_utilization` are the
post-local-gain result. `gain_map.local_weight_mean` and
`gain_map.local_weight_p95` are serialized diagnostics.

## Acceptance checklist

Validate each generated HEIC with `inspect` and `verify`, or each Ultra HDR JPEG
with `verify`, then test the file on a compatible HDR device. Use at least these scenes:

1. Daytime diffuse light: stable midtones, restrained white walls, natural skin
   and vegetation.
2. Strong highlights: lights, sunlight, and reflections roll smoothly into HDR
   without dead-white plates, fluorescent colour, or gain halos.
3. High-ISO night: target middle grey remains dark, exposure does not lift the
   whole scene into daytime, and black surroundings stay free of gain pumping.

The automated suite covers curve continuity/monotonicity, gamma round trips,
local gain behaviour, common-RGB reconstruction, ISO gain-map metadata round
trips, and HEIC/TMAP and Ultra HDR JPEG/R encode/decode. Visual device review
remains the final display-specific acceptance gate.

## Converting a folder

```powershell
HyperDR convert D:\photos --output D:\hdr --recursive --skip-existing
```

Skipping is fingerprint based, so a repeated pass is cheap: anything already
rendered from the same input with the same settings is skipped before the
decoder is touched, and anything rendered with *different* settings is
regenerated. Re-running after a card copy therefore converges on whatever is
actually on disk.

The graphical panel deliberately does not do this. It converts one photograph at
a time, because the settings worth reaching for a slider over are the ones that
differ per image; a folder that should share one look is what the command line
above is for.

## Continuous integration

`.github/workflows/ci.yml` is configured to build the dependency-free Windows
core in Debug and Release, run the panel tests on two Python versions, parse the
front-end, check the panel's `data-role` contract, validate the checked-in JSON
schemas, and confirm that `schema/settings.json` matches what the built converter
emits. It then builds and tests the full codec-enabled Windows configuration.
A change is ready to merge only when all of these jobs are green.

## Scope and limitations

Only local files are processed. Existing maker notes and arbitrary private XMP
are not copied; essential photographic metadata is rebuilt into compact Exif and
standards-oriented XMP, now including artist, copyright, lens make and model,
35 mm equivalent focal length, a Software tag, and the camera's GPS fix when it
recorded one. A fix that LibRaw did not parse is omitted rather than guessed.
GPU encoding remains outside this project's scope.

## iPhone LAN panel

The browser panel supports authenticated LAN uploads, isolated conversion jobs,
WebGPU extended-range live preview, exact Adaptive HDR result preview, and HEIC/
Ultra HDR JPEG download. Start `Start.bat` and open the printed tokenized iPhone URL. Plain HTTP
supports upload and conversion; trusted HTTPS is required for WebGPU on a LAN
origin, because a browser exposes WebGPU only in a secure context and
dismissing a certificate warning does not create one.

`Setup-HTTPS.bat` handles that once per computer: it installs `mkcert` through
winget when needed, creates a certificate authority belonging to that machine
alone, issues the server certificate into `%LOCALAPPDATA%\HyperDR\tls`, and
exports the public root certificate for the phone. No authority and no private
key is ever shipped in a release archive. When the router later assigns a new
address, `Start.bat` re-issues the server certificate from the same authority
automatically and the phone needs no changes. See `docs/iphone-lan.md`.

## Contributing and security

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
[SECURITY.md](SECURITY.md) records the panel's threat model and how certificates
and private keys are handled. User-visible changes are recorded in
[CHANGELOG.md](CHANGELOG.md).

## License

This project is licensed under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses and
distribution considerations of build dependencies.
