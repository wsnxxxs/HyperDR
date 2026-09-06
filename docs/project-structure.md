# Project structure

The repository is organised around the product surfaces first. Implementation
layers live one level below those surfaces and should stay invisible in feature
descriptions unless they affect behaviour.

```text
HyperDR/
├── apps/
│   ├── panel/          # Browser/iPhone UI and its local Python server
│   └── desktop/        # Windows Tauri shell around the panel
├── modules/            # Native converter, renderer, formats, CLI and reports
├── HyperDR_Model/      # Optional “优化” inference and training project
├── docs/               # Current guides and references
│   └── archive/        # Dated evidence that is no longer living guidance
├── schema/             # Checked-in settings and report contracts
├── scripts/            # Local launch, Windows setup and development helpers
├── packaging/          # Release assembly, smoke test and install guide
├── tests/              # Checks that cross more than one owning area
├── cmake/              # Native build helpers
├── Start.bat           # Browser/LAN entry point
└── Setup-HTTPS.bat     # One-time iPhone HDR setup
```

## Start from the feature

| Feature or behaviour | Primary owner | Related guide |
| --- | --- | --- |
| Single-photo preview, controls, conversion and download | `apps/panel/` | [Panel guide](../apps/panel/README.md) |
| Windows desktop window, sidecar lifecycle and native file drop | `apps/desktop/` | [Desktop guide](../apps/desktop/README.md) |
| Folder conversion, CLI settings, resume and reports | `modules/app/` | [CLI reference](cli-reference.md) |
| Tone, exposure, colour and HDR expansion | `modules/look/`, `modules/gainmap/` | [Rendering behaviour](rendering.md) |
| JPEG/HEIF/AVIF/RAW support and metadata | `modules/codec/`, `modules/container/` | [CLI reference](cli-reference.md) |
| Embedded model-based gain map | `HyperDR_Model/models/`, `modules/gainmap/src/ncnn_runtime.cpp`, `apps/panel/hyperdr_panel/model.py` | [Model integration](model-integration.md) |
| iPhone/LAN/HTTPS setup | `scripts/` | [iPhone LAN guide](iphone-lan.md) |
| Release contents and installation | `packaging/` | [Release guide](../packaging/README.md) |

If a change fits one row, keep it there. Add a new top-level directory only
when it represents a new independently runnable product surface or a genuinely
separate data lifecycle.

## Native converter modules

The C++ converter keeps seven small build boundaries because their dependency
order is useful in practice:

```text
app → codec → gainmap → look → image → foundation
              └──────→ container → foundation
```

- `foundation`: file IO, JSON, hashing and shared numeric helpers
- `image`: image buffers, colour and transfer functions
- `look`: photographic rendering intent
- `container`: Exif and gain-map container metadata
- `gainmap`: SDR base, gain-map rendering and reconstruction
- `codec`: image decoding, encoding and verification
- `app`: CLI behaviour, settings, batches, resume and reports

Public headers remain under each module's `include/hyperdr/<module>/` tree;
implementation stays in `src/`, and a module's focused C++ checks stay in its
own `tests/` directory. This is an existing build boundary, not a template that
every new feature must copy.

## Shared contracts

Only three paths normally require coordinated edits:

| Change | Keep in sync |
| --- | --- |
| Conversion setting | `modules/app/src/schema.cpp` → generated `schema/settings.json` → panel adapters (`hyperdr_panel/schema.py` and browser `settings/schema.js`) |
| Report field or version | `modules/app/src/report.cpp` → `schema/report.json` → `docs/report-schema.md` |
| Panel endpoint | `apps/panel/hyperdr_panel/` ↔ `apps/panel/web/js/` |

Everything else should have one obvious owner. Prefer calling that owner over
introducing a second representation in another layer.

## Local working state

Build trees (`build*`), `dist/`, `output/`, `hdr-workspace/`, `.pytest_cache/`,
desktop `node_modules/` and Rust targets, model `.venv/` and model reports are
generated or private local state. They are ignored by Git and are not part of
the repository structure.

Do not automatically clean or move `hdr-workspace/`, model checkpoints,
datasets, or reports: they may contain user photographs or expensive local
work. The commonly recognised build names are `build/`, `build-core/`,
`build-release/`, and `build-codecs-win/`; using one of them lets the panel find
the converter without extra configuration.

For the feature-first iteration checklist and proportionate validation commands,
see [development.md](development.md).
