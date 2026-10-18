# HyperDR

`HyperDR` is a C++20 command-line converter for ARW, DNG, JPEG, PNG, HEIC,
HEIF/HIF, and AVIF images, now targeting macOS 26 on Apple Silicon. It exports graded SDR JPEGs and six real HDR
representations: Apple-compatible Adaptive HDR HEIC (a Display P3 SDR base plus
an ISO 21496-1 single-channel gain map), a JPEG with an ISO 21496-1 gain map
(`iso-gainmap-jpeg`; `ultrahdr` is accepted as an alias for now), 10-bit ITU-R
BT.2100 PQ and HLG HEIC, and the same two BT.2100 renditions as 10-bit AVIF. PQ,
HLG and AVIF encode the directly rendered linear HDR image; SDR samples
are never merely relabelled HDR.

**Every encoding HyperDR writes, it also reads.** An HDR photograph given as
*input* keeps its highlight range: an Ultra HDR JPEG is read through its gain
map rather than through its backward-compatible SDR primary, an Adaptive HDR
HEIC through its `tmap` gain map, and a BT.2100 PQ or HLG file -- HEIC or AVIF,
4:2:0, 4:2:2 or 4:4:4, which is what cameras such as Sony's write -- through the
exact inverse of the transfer function this project encodes with. All of them
land in the same linear Display P3 working space as a RAW, so the look controls,
the preview and the six exports share one pipeline whatever the input was.

SDR JPEG and 16-bit TIFF support `--output-gamut auto|srgb|p3`. The defaults
are sRGB for JPEG and Display P3 for TIFF; both pixels and embedded ICC match
the selected space, and the preview applies the same final mapping. The HDR
`--clamp-srgb` restriction does not affect SDR exports. PQ/HLG output maps HDR
colour into Rec.2020 rather than first reducing it to P3. Input colour
interpretation and its source (ICC, CICP, RAW or an assumption) are included in
previews and reports. `--color-gamut` remains an untagged-input fallback with
sRGB transfer, not an output choice or a PQ/HLG override.

Creative colour LUTs are independent of RAW sensor linearization. Import a
1D/3D `.cube`, declare its input/output colour spaces, and choose SDR JPEG or
any of the six HDR exports. RAW can feed S-Log3/S-Gamut3.Cine LUTs before
development; ordinary photo LUTs can grade RAW, SDR and existing HDR sources.
See [the architecture review and LUT guide](docs/color-lut-pipeline.md) for the
stage choices, HDR highlight policy and command examples.

Camera, lens and capture settings are read from the input's Exif and carried to
the output. ISO is not merely copied: the gain map weighs local expansion
against sensor noise with it, so a high-ISO HEIC is rendered as the high-ISO
photograph it is.

The `photographic` look uses a photographic toe, a shared linear middle, and a
smooth HDR shoulder. It keeps SDR and HDR identical below the shoulder, puts
qualified highlights into HDR headroom, and applies shared chroma processing
before the two luminance outputs split. It is the only renderer; the earlier
`neutral` one has been removed, and `--look neutral` is now rejected.

HyperDR now targets macOS on Apple Silicon with a native SwiftUI application
and a folder-capable CLI. The Python/Web panel and Windows desktop shell remain
as migration references. The optional “优化” action
adds a model-produced gain map without replacing the normal renderer. Start a
change from the [feature ownership map](docs/project-structure.md); the native
converter's internal layers are documented there only as a secondary concern.

## Repository guide

- [`modules/`](modules/) contains the layered C++ core and command-line app.
- [`apps/panel/`](apps/panel/) contains the Python browser-panel server and its
  web client.
- [`apps/apple/`](apps/apple/) contains the new SwiftUI application and Swift packages.
- [`apps/desktop/`](apps/desktop/) retains the archived Windows desktop shell.
- [`HyperDR_Model/`](HyperDR_Model/) contains the optional ML training and
  inference project.
- [`tests/`](tests/) contains cross-component Python, JavaScript, PowerShell,
  Swift, and C++ gate tests; module-local C++ tests stay beside their modules.
- [`docs/`](docs/README.md) indexes every guide and reference in the project,
  while [`scripts/`](scripts/) and [`packaging/`](packaging/) contain
  development, Windows setup, and release tooling.

Generated build trees, release archives, caches, local model reports, and
temporary diagnostics are not part of the source tree. See the
[project structure guide](docs/project-structure.md) for ownership, build
directory names, and cleanup conventions.

## Quick start

Build the macOS CLI and C ABI using the instructions below. The native SwiftUI
application is being developed in `apps/apple/`.

## Windows archive

Windows development ended at [`a43d46a`](https://github.com/wsnxxxs/HyperDR/tree/a43d46a).
Use that revision for Windows build and release instructions. The current branch
supports macOS on Apple Silicon; iPhone and iPad work is deferred.

## Build on macOS (Apple Silicon)

Install the Command Line Tools (`xcode-select --install`), Homebrew, and Git.
Full Xcode is not required for the native CLI and C ABI libraries.

```sh
brew install cmake ninja node python@3.12 pkg-config
export PATH="$(brew --prefix python@3.12)/libexec/bin:$PATH"

# Dependency-free renderer, CLI, and C ABI.
cmake --preset macos-arm64-core
cmake --build --preset macos-arm64-core
ctest --preset macos-arm64-core
python3 scripts/test.py native --build-dir build-core
python3 scripts/test.py frontend
```

For image decoding, JPEG/TIFF, Ultra HDR JPEG/R and PQ/HLG AVIF exports,
install the pinned vcpkg checkout and build with codecs:

```sh
git clone https://github.com/microsoft/vcpkg.git "$HOME/vcpkg"
git -C "$HOME/vcpkg" checkout 43643e1f5cf73db40d0d4bd610183348eb09b24e
"$HOME/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
cmake --preset macos-arm64-codecs
cmake --build --preset macos-arm64-codecs
ctest --preset macos-arm64-codecs
build/HyperDR model-list --json
```

These presets target macOS 26 and write only to `build-core/` and `build/`.
Both builds produce `HyperDR`, `libhyperdr.a`, and `libhyperdr.dylib` at the
build root. The C11 header is `modules/capi/include/hyperdr/hyperdr.h`.
The codec preset uses `cmake/triplets/arm64-osx.cmake` to keep the transitional
libheif/libde265 decoder libraries dynamic. It disables LibRaw OpenMP and
libheif's GPL HEVC encoder feature: this macOS build reads HEIC but HEVC exports fail with
`this build has no HEVC encoder` until the VideoToolbox backend is added.
HEVC fixture-generation tests report their skip; AVIF and JPEG/R tests still run.
This transitional libheif build is for direct desktop development/distribution;
it is not the planned App Store build.

## Usage

```text
HyperDR convert <file-or-directory> --output <directory> [options]
HyperDR inspect <file.heic> [--json]
HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]
HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]
HyperDR preview-frame <image> --output <preview.hpf> [look options]
HyperDR model-gain <image> --ai-model <id> [AI post options]
HyperDR model-list [--json]
HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>
HyperDR curve [look options] [--samples <N>]
HyperDR schema
```

Within the converter, every setting is declared once, in one C++ table.
`--help`, the command-line parser, the resume fingerprint and the report's
settings block are all generated from it, so those converter surfaces cannot
drift apart. `HyperDR schema` prints that table as JSON, and the checked-in
`schema/settings.json` is the generated contract used by the panel backend and
contract checks. The browser UI also has a small local schema for labels,
widgets and request mapping; update that adapter when a setting is exposed in
the UI.

The full option list, exit codes, per-encoding behaviour, resume fingerprinting,
and look-control ranges are in
[docs/cli-reference.md](docs/cli-reference.md).

## Rendering and compatibility guarantees

What the renderer promises about its output, and the manual scene checklist a
release still has to pass, are in [docs/rendering.md](docs/rendering.md).

## Report schema 12

The `--report` contents, geometry fields, and headroom fields are documented in
[docs/report-schema.md](docs/report-schema.md), alongside the machine-readable
[`schema/report.json`](schema/report.json).

## Acceptance checklist

The three required scenes and what the automated suite does and does not cover
are in [docs/rendering.md](docs/rendering.md#acceptance-checklist).

## Converting a folder

```powershell
HyperDR convert D:\photos --output D:\hdr --recursive --skip-existing
```

Skipping is fingerprint based, so a repeated pass is cheap: anything already
rendered from the same input with the same settings is skipped before the
decoder is touched, and anything rendered with *different* settings is
regenerated. Re-running after a card copy therefore converges on whatever is
actually on disk.

The graphical panel edits one photograph at a time, with undo/redo, per-tab
refresh recovery, and a history of immutable exports. A failed or cancelled
retry leaves earlier results available for download. Each new photo gets its
own session; sessions and their exports expire after the configured idle time
(24 hours by default). Use the CLI for a folder that should share one look.

## Continuous integration

Local checks and `.github/workflows/ci.yml` share `python scripts/test.py`.
Run it after configuring `build-core`, or select `panel`, `frontend`, or `native`
for a focused check. The [development guide](docs/development.md#validate-only-the-affected-behaviour)
lists prerequisites and build options.

CI defines macOS core Debug/Release jobs, a codec build with a GPL dependency
gate, ASan/UBSan C ABI checks, and the reference frontend suite.
Run `actionlint .github/workflows/ci.yml` locally. Hosted execution is verified
after an authorized push.

## Scope and limitations

Only local files are processed. Existing maker notes and arbitrary private XMP
are not copied; essential photographic metadata is rebuilt into compact Exif and
standards-oriented XMP, now including artist, copyright, lens make and model,
35 mm equivalent focal length, a Software tag, and the camera's GPS fix when it
recorded one. A fix that LibRaw did not parse is omitted rather than guessed.
HEVC encoding will use the planned VideoToolbox backend.

## iPhone LAN panel

The Windows LAN launchers are retained as migration references. Use the
[frozen Windows revision](https://github.com/wsnxxxs/HyperDR/tree/a43d46a) and
[LAN guide](docs/iphone-lan.md) for that version. The current application targets
macOS; native iPhone and iPad work is deferred.

## Development and security

The [feature-first development guide](docs/development.md) maps user-visible
behaviour to its owner and lists the smallest useful checks for each area.
[SECURITY.md](SECURITY.md) records the panel's threat model and how certificates
and private keys are handled. User-visible changes are recorded in
[CHANGELOG.md](CHANGELOG.md).

## License

This project is available under the [GNU Affero General Public License v3.0](LICENSE)
or a commercial license ([LICENSING.md](LICENSING.md)). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses and
distribution considerations of build dependencies.
