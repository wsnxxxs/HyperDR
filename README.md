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

Build trees belong in one of the four names the tooling already knows —
`build/`, `build-core/`, `build-release/`, `build-codecs-win/`. They are listed
with their consumers in the
[project structure guide](docs/project-structure.md).

## Usage

```text
HyperDR convert <file-or-directory> --output <directory> [options]
HyperDR inspect <file.heic> [--json]
HyperDR verify <file.heic|file.jpg> [--reconstruct <preview.tiff>]
HyperDR thumbnail <image> --output <preview.jpg> [--max-edge <pixels>]
HyperDR preview-frame <image> --output <preview.hpf> [look options]
HyperDR model-input <image> --output <linear-p3.f32> --report <recipe.json>
HyperDR curve [look options] [--samples <N>]
HyperDR schema
```

Every setting is declared once, in one table. `--help`, the command-line parser,
the resume fingerprint and the report's settings block are all generated from it,
so a new setting cannot appear in some of those places and not others.
`HyperDR schema` prints that table as JSON, and `schema/settings.json` is that
output checked in for the browser panel to validate against.

The full option list, exit codes, per-encoding behaviour, resume fingerprinting,
and look-control ranges are in
[docs/cli-reference.md](docs/cli-reference.md).

## Rendering and compatibility guarantees

What the renderer promises about its output, and the manual scene checklist a
release still has to pass, are in [docs/rendering.md](docs/rendering.md).

## Report schema 7

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

The graphical panel does not do this. It converts one photograph at a time,
because the settings worth reaching for over a slider are the ones that differ
per image; a folder that should share one look is what the command line above
is for.

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

Double-click `Start.bat` and open the printed tokenized iPhone URL to upload
photos, tune settings with a live preview, and download the converted HEIC or
Ultra HDR JPEG. Plain HTTP covers upload and conversion; the true-HDR WebGPU
preview needs trusted HTTPS, which `Setup-HTTPS.bat` sets up once per computer.
The full guide, covering the two iPhone trust steps, manual certificate setup,
and security notes, is in [docs/iphone-lan.md](docs/iphone-lan.md).

## Contributing and security

Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.
[SECURITY.md](SECURITY.md) records the panel's threat model and how certificates
and private keys are handled. User-visible changes are recorded in
[CHANGELOG.md](CHANGELOG.md).

## License

This project is licensed under the [MIT License](LICENSE). See
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the licenses and
distribution considerations of build dependencies.
