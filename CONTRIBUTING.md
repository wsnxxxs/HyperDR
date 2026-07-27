# Contributing to HyperDR

Thanks for considering a contribution.

See [docs/project-structure.md](docs/project-structure.md) for a map of the
repository before choosing where to make a change.

## Before you start

- Open an issue first for substantial changes so the intended behaviour can be discussed.
- Keep pull requests focused and avoid unrelated formatting changes.
- Do not include photographs, camera RAW files, generated outputs, certificates, access tokens, or other private data.

## Development checks

Use the core-only build when you are changing renderer logic that does not require
codecs:

```powershell
cmake -S . -B build-core -DHYPERDR_WITH_CODECS=OFF
cmake --build build-core --config Release
ctest --test-dir build-core -C Release --output-on-failure
```

For codec or integration changes, also run the codec-enabled build described in
[README.md](README.md). Add or update a focused test when behaviour changes; a
module's tests live in `modules/<module>/tests/` and link only that module, so put
a test beside the layer it exercises.

If a change adds, removes, or renames a conversion setting, declare it once in
`settings()` in `modules/app/src/schema.cpp` — the parser, `--help`, the
fingerprint and the report all derive from that table — and regenerate the
schema the browser panel reads:

```powershell
.\build\HyperDR schema > schema\settings.json
```

CI fails if that file is stale. Python panel changes should also run:

```powershell
python -m pytest tests/python -q
```

## Pull requests

Describe the problem, the approach, tests run, and any compatibility impact.
For changes that affect rendered output, include representative before/after
evidence without publishing private images.

By contributing, you confirm that you have the right to submit the work under
the repository's MIT License.
