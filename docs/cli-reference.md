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

Recommended photographic conversion:

```powershell
HyperDR convert photo.ARW --output out --look photographic --depth 10 `
  --contrast 1.08 --vibrance 0.12 --headroom-max 4 --report out\report.json
```

## Encodings

`--encoding avif-pq` and `--encoding avif-hlg` write 10-bit BT.2100 AVIF using
the same reconstructed HDR image, the same Rec.2020 matrix, and the same
transfer functions as the HEIC paths, so they differ only in container and
codec. There is no gain-map AVIF: libavif's support for it is still behind an
experimental build flag, and Adaptive HEIC and Ultra HDR JPEG already cover
that case.

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

## Verification, resume, and caching

Conversions decode-verify their output by default. For trusted high-volume batch
work, `--no-verify` skips that final self-check; reports then record
`self_verified: false` independently of conversion success.

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

`--decode-cache <dir>` stores the decoded, bounded linear image so that manual
CLI runs differing only in look controls can skip the RAW decode entirely.

## Look controls

The GUI separates whole-image brightness, **HDR brightness headroom**, and
**tone-region coverage**. The panel starts whole-image brightness at +0.6 EV
and ranges from 0..+2 EV; it is applied after exposure selection to both the SDR
base and HDR rendition. The panel resets all image-scoped adjustments whenever
a new photo is opened. The standalone CLI remains neutral at 0 EV unless
`--exposure-bias` is supplied.
`--exposure auto` is honoured for RAW only. A JPEG, PNG or HDR input is already
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
