# macOS display-domain T2

This directory prepares gate T2 from `hyperdr.display-domain/v1`. It does not
run on pushes or pull requests. The sole GitHub Actions job is
`workflow_dispatch` on `macos-15`, has a five-minute timeout, and must be
started deliberately by a repository operator because private-repository macOS
minutes may be billable.

The fixed fixture pair is synthetic. Both HEIC files contain exactly the same
SDR base, encoded gain map, HEVC payloads, and metadata except for one byte: the
big-endian gain-map gamma numerator is `1` in the control and `2` in the probe.
`generate_fixtures.py verify` enforces the file hashes, exact ToneMapImage
payloads, and that single-byte invariant before Core Image sees either file.
No corpus or test split is read.

On macOS 15, `CoreImageT2.swift` uses ImageIO to require an ISO auxiliary gain
map, loads the SDR base and gain map independently, scales the native 2x2 gain
map to the 8x4 base with Core Image, and calls
`CIImage.applyingGainMap(_:headroom:)`. The registered physical headrooms are
0.5, 1.0, and 1.5 stops; the harness passes `2^H` because the Core Image API accepts a
linear headroom ratio.

The workflow then compiles the repository's actual
`modules/gainmap/src/reconstruct.cpp` directly with its ISO metadata parser.
It reconstructs the exact base and gain samples decoded by Core Image, avoiding
HEVC and color-management differences as confounders. The C++ helper also emits
the competing "inverse gamma before spatial interpolation" result. The final
validator requires:

- exact decoded base and gain pixels across the only-gamma pair;
- pixelwise Core Image/C++ agreement at all three physical headrooms;
- the gamma=1 control, where both interpolation orders coincide, to pass;
- the gamma=2 probe to be materially closer to the registered C++ code-domain
  order than to the competing decoded-domain-first order.

The canonical result is `t2-output/t2-report.json`, validated against the fixed
schema and uploaded together with all intermediate evidence. Until that report
has `status: pass` on a real macOS 15 run, T2 remains pending.

## Running it on a borrowed Mac instead of the hosted runner

`run_t2_local.sh` performs the same steps, on the same frozen inputs, with the
same decision rule; it adds only a preflight and a zipped evidence bundle.
`RUNBOOK-mac.md` is the operator procedure, including what to check before
borrowing the machine and how to read each outcome.

```text
bash tests/macos_t2/run_t2_local.sh
```

## Source identity is line-ending independent

`source_sha256` in the manifest hashes text sources with CRLF normalised to LF
(`sha256_source`, defined identically in `generate_fixtures.py` and
`validate_t2.py`); fixture binaries and the generator executable keep their
plain byte hash. The sources are governed by `* text=auto`, so a Windows
checkout holds CRLF exactly where a macOS checkout holds LF: hashing the bytes
on disk pinned source identity to the checkout that generated it and would have
failed the provenance gate on macOS, the only platform that can run T2. The
recorded digests were re-derived under this rule. Fixture bytes, the acceptance
thresholds, and the headroom nodes were not touched.

The standalone C++ reference can also be syntax-checked without the Windows-only
application build:

```text
cmake -S tests/macos_t2 -B build-t2-reference
cmake --build build-t2-reference --config Release
```

Fixture regeneration is intentionally separate from the lightweight Mac job.
With an exact full-codec build of this branch:

```text
python tests/macos_t2/generate_fixtures.py regenerate --hyperdr <HyperDR executable>
python tests/macos_t2/generate_fixtures.py verify
```
