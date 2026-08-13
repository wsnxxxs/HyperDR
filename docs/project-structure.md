# Project structure

HyperDR is organised as seven layered modules. Each one owns a directory under
`modules/` and publishes its headers from its own `include/` root.

```text
HyperDR/
├── modules/
│   ├── foundation/     # Numbers, JSON, file IO, hashing, the row-parallel pool
│   ├── image/          # The float image, colour primaries, transfer functions, resampling
│   ├── look/           # Rendering intent: tone curve, scene analysis, exposure, headroom
│   ├── container/      # On-disk metadata: HEIF boxes, ISO 21496-1 gain map, Exif/XMP
│   ├── gainmap/        # SDR base + gain map rendering, and reconstruction
│   ├── codec/          # Reading and writing image files
│   └── app/            # Settings, discovery, resumable batches, reporting, the CLI
│       └── each module: include/hyperdr/<module>/  public headers
│                        src/                       implementation (+ src/internal/)
│                        tests/                     that module's tests
├── apps/panel/         # Local browser control panel (Python, standard library only)
├── HyperDR_Model/      # Optional ML training, evaluation, and gain-map inference
├── cmake/              # Build helpers: compiler settings, module and test registration, codecs
├── docs/               # Every guide and reference, indexed by docs/README.md
│                         audits/ holds dated point-in-time reports
├── packaging/          # Release building, unpacked-archive smoke test, and install guide
├── schema/             # Settings vocabulary and report JSON Schema
├── scripts/            # Windows setup, LAN, TLS, firewall, and codec helpers
│                         hyperdr_tls.ps1 holds the certificate paths and
│                         issuing logic shared by both launchers
├── tests/              # Cross-component tests: python/, js/, powershell/,
│                         display_gates/ (C++ CTest), macos_t2/ (Swift + Python)
├── Start.bat           # Double-click entry point for the browser panel
├── Setup-HTTPS.bat     # One-time trusted-HTTPS setup for iPhone true HDR
├── CMakeLists.txt      # Options, module list, install and packaging
├── vcpkg.json          # Native dependency manifest
├── CHANGELOG.md        # User-visible changes by release
└── README.md           # Project overview and command-line guide
```

## Layers

Dependencies run strictly upward, and each module can only include headers from
modules it links. An accidental upward dependency therefore fails to compile
rather than merely being impolite — the layering is enforced by the build, not by
convention.

```text
app  ──▶ codec ──▶ gainmap ──▶ container ──▶ foundation
                       └────▶ look ──▶ image ──▶ foundation
```

| Module | Answers | Knows nothing about |
| --- | --- | --- |
| `foundation` | How do we hash, parse, emit, and write bytes safely? | Images |
| `image` | What is a pixel, and what colour space is it in? | Photographs |
| `look` | What should this photograph look like? | Gain maps, files |
| `container` | How is metadata laid out on disk? | Rendering |
| `gainmap` | How does one image become a base plus a gain map? | Containers' pixel codecs |
| `codec` | How do we read and write actual image files? | Batches, settings |
| `app` | What did the user ask for, and did it work? | — |

`codec` is the only module with third-party image dependencies (LibRaw, libheif,
libavif, libultrahdr, libjpeg, libpng, lcms2). Everything below it builds and
tests with nothing but a C++20 compiler, which is why `-DHYPERDR_WITH_CODECS=OFF`
still runs almost the whole test suite.

## Where to make changes

| Change | Location |
| --- | --- |
| Tone curve, exposure, or headroom behaviour | `modules/look/` |
| Gain-map maths, or the SDR base render | `modules/gainmap/` |
| A new setting, or CLI behaviour | `modules/app/src/schema.cpp` |
| Encoders, decoders, or verification | `modules/codec/` |
| HEIF structure, Exif, or gain-map metadata | `modules/container/` |
| JSON, file IO, or the thread pool | `modules/foundation/` |
| Browser panel behaviour | `apps/panel/hyperdr_panel/` |
| HyperDR_Model inference orchestration | `apps/panel/hyperdr_panel/model.py` and `docs/model-integration.md` |
| Panel visual design | `apps/panel/web/` |
| Build options, warnings, or test registration | `cmake/` |
| Windows and LAN setup | `scripts/` and `docs/iphone-lan.md` |
| Certificate paths, issuing, and re-issuing | `scripts/hyperdr_tls.ps1` |
| Release packaging, six-format smoke test, and install instructions | `packaging/` |

`hyperdr` is the internal C++/Python identifier. `HyperDR` is the public product
name and command-line executable.

## Local and generated files

The repository root should contain source, documentation, and launch files only.
CMake build trees (`build*`), packaged releases (`dist/`), test caches,
`__pycache__` directories, `.tmp-*` diagnostics, and compiler objects are local,
reproducible output and are ignored by Git. They can be deleted when no build or
diagnostic process is using them.

`HyperDR_Model/.venv/`, trained `*.pt` checkpoints, datasets, and generated
`HyperDR_Model/reports/` are also machine-local. Treat these as potentially
expensive or private assets: normal workspace cleanup preserves them even though
Git ignores them. `hdr-workspace/` is the panel's own session storage and holds
the photographs you fed it, so it is cleanup-preserved for the same reason.

### Build directories

`build*` is gitignored, so any name works — which is how three abandoned trees
once accumulated at the root. Four names are already known to the tooling; use
one of them and a later reader can tell what a tree was for.

| Directory | Configuration | Who expects it |
| --- | --- | --- |
| `build/` | Codec-enabled, the shippable one | README, the CI codecs job, `executable.py` |
| `build-core/` | `-DHYPERDR_WITH_CODECS=OFF` | CONTRIBUTING, the CI core job, `executable.py` |
| `build-release/` | Codec-enabled, for packaging | `packaging/package-release.ps1` default |
| `build-codecs-win/` | Codec-enabled, for the LAN panel | `scripts/start_hyperdr_lan.ps1` |

`apps/panel/hyperdr_panel/executable.py` searches all four plus `bin/` and
`PATH`, so a build in one of them is found by the panel without configuration.
Anything else needs `HYPERDR_EXECUTABLE` set by hand.

## Single sources of truth

Several things used to exist in more than one copy and drifted apart. Each now
has exactly one authority; adding a second copy of any of them is a regression.

| Knowledge | Authority | Consumers |
| --- | --- | --- |
| Every conversion setting: name, flag, type, range, default, help | `settings()` in `modules/app/src/schema.cpp` | the CLI parser, `--help`, the resume fingerprint, the run report, `HyperDR schema`, and through that the panel |
| The settings vocabulary, for the panel | `schema/settings.json`, generated by `HyperDR schema` | `apps/panel/hyperdr_panel/schema.py`, and every validator built from it |
| Report schema 8 | `modules/app/src/report.cpp`, documented by `schema/report.json` | CLI `--report`, the panel, and `report_test` which checks emitted reports against the schema |
| The convert command line | `build_argv` in `apps/panel/hyperdr_panel/command.py` | the job runner and `/api/command`, which the browser displays |
| The native preview rendition | `make_gain_map` + `reconstruct_gain_map`, packaged by `HyperDR preview-frame` | the panel's WebGPU/WebGL/CPU presentation paths; JavaScript does not rerun the photographic algorithm |
| JSON emission | `json::Writer` in `modules/foundation` | the run report, the curve export, HEIF inspection, the resume sidecar, the decode-cache sidecar, the schema |
| Path comparison and atomic writes | `modules/foundation/include/hyperdr/foundation/file_io.hpp` | output-collision detection, self-overwrite refusal, discovery, every file the converter writes |
| Luminance, smoothstep, percentiles, rationals | `foundation/math.hpp`, `foundation/rational.hpp`, `image/color.hpp` | the whole renderer |
| Version string | `foundation/version.hpp` | CLI banner, Exif Software tag, resume fingerprint, decode-cache key, report, schema |
| Resolution bounding | `modules/image/src/resample.cpp` | `--preview-max-edge` and `thumbnail` |
| BT.2100 transfer functions, both directions | `modules/image/include/hyperdr/image/transfer.hpp` | the HEIF and AVIF encoders, and the decoders that read those files back |
| CICP decoding: transfer, primaries, the ICC path | `modules/codec/src/internal/cicp.hpp` | the JPEG, PNG, HEIF and AVIF decoders |
| Exif read onto a decoded image | `read_exif` in `modules/container` plus `modules/codec/src/internal/metadata.hpp` | the JPEG, HEIF, AVIF and Ultra HDR decoders |
| Codec availability | `modules/codec/include/hyperdr/codec/availability.hpp` and `src/unavailable.cpp` | every caller, none of which contains a `#if` |

## Tests

Each module's tests live beside it and link only that module, so a test that
reaches across a layer boundary fails to link. They are plain programs that throw
on failure — no framework to install:

```powershell
ctest --test-dir build --output-on-failure
ctest --test-dir build -R schema        # one module's worth
python -m pytest tests/python -q        # the browser panel
./tests/powershell/test_hyperdr_tls.ps1 # the shared HTTPS helpers
```

`tests/` holds what cannot live beside a single module. `tests/python/` is the
panel suite and also drives the two Node runners in `tests/js/` — the C++/JS
tone-curve port and the WebGPU HDR contract — so those need no separate command.
`tests/display_gates/` is registered with CTest like a module's tests.
`tests/macos_t2/` is the manual macOS Core Image adjudication: it runs from
`.github/workflows/macos-display-t2.yml` or, on a borrowed Mac, from
[its own runbook](../tests/macos_t2/RUNBOOK-mac.md).
