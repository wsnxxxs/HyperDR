# Development workflow

HyperDR is currently maintained by one developer. Start an iteration from the
user-visible behaviour to change, then touch the smallest owning area. A new
layer, abstraction, compatibility branch, or test harness needs a concrete
current use case; possible future needs are not enough on their own.

## Find the feature owner

| Behaviour | Start here |
| --- | --- |
| Tone, exposure, highlight recovery, HDR expansion | `modules/look/`, then `modules/gainmap/` |
| File support, metadata, encoding, verification | `modules/codec/`, `modules/container/` |
| CLI settings, folder conversion, resume, reports | `modules/app/` |
| Browser and iPhone experience | `apps/panel/` |
| Windows desktop lifecycle and native integration | `apps/desktop/` |
| Optional “优化” model behaviour | `HyperDR_Model/` and `apps/panel/hyperdr_panel/model.py` |
| Windows setup and local launch | `scripts/` |
| Release archive and installer | `packaging/` |

The lower-level module map is in [project-structure.md](project-structure.md),
but it should not be the starting point for describing a feature.

## Keep the three shared contracts in sync

- A conversion setting starts in `settings()` in
  `modules/app/src/schema.cpp`. Regenerate `schema/settings.json` with a freshly
  built `HyperDR schema` after changing it.
- A report change updates `modules/app/src/report.cpp`, `schema/report.json`,
  and [report-schema.md](report-schema.md) together.
- A panel API change updates the Python endpoint under
  `apps/panel/hyperdr_panel/` and its caller under `apps/panel/web/js/` together.

## Validate only the affected behaviour

Local development and CI use the same entry point. Install Python 3.11+,
pytest (`python -m pip install pytest`), Node.js 20+, and PowerShell 7. Native
checks also need the Windows C++ build tools and a configured CMake build.

```powershell
# Configure the dependency-free core once
cmake -S . -B build-core -DHYPERDR_WITH_CODECS=OFF

# Full routine suite: panel + HTTPS, front-end, native build + CTest + contracts
python scripts/test.py

# Select only the affected area while iterating
python scripts/test.py panel
python scripts/test.py frontend
python scripts/test.py native --build-dir build-core --config Release
```

The native suite builds the selected configuration before running CTest, compares
the browser curve and checked-in settings schema against that exact converter,
and parses the report schema. Missing native prerequisites fail the suite.
The panel suite needs no converter or Node.js. The front-end suite runs the
history and WebGPU configuration behavior tests, parses JavaScript modules, and
checks role wiring and translations. GPU rendering and responsive layout still
need a real browser/device check when those features change; source-text
assertions cannot verify them.

For a focused Python regression, `python -m pytest tests/python/test_session.py -q`
remains available. Native integration tests live separately in `tests/native/`
so a panel run never silently picks up an unrelated local converter.
Plain `python -m pytest` also selects only `tests/python/`.

Run the codec-enabled build or `packaging/test-release.ps1` only when the change
touches codecs, native runtime assembly, installation, or release behaviour.
Run the macOS T2 workflow only when its gain-map interpolation contract changes.
A focused regression check is useful when behaviour changed; broad speculative
coverage is not a requirement.

## Before finishing an iteration

- Describe user-visible changes in `CHANGELOG.md` and the relevant feature
  guide. Implementation-only refactors do not need product copy.
- Confirm generated schemas are current when their contracts changed.
- Do not commit photographs, RAW files, generated outputs, certificates,
  tokens, model environments, or private datasets.
- Leave build trees, `dist/`, `output/`, `hdr-workspace/`, model reports, and
  caches out of source review; they are local working state.
