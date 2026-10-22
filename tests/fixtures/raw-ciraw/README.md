# Frozen RAW migration measurements

Captured on macOS 27.0.1, build 26A434 before removing LibRaw (R3).
The old implementation was LibRaw 0.22.1, half-size demosaic. The Apple path
uses the system default decoder, neutral settings, and preview edge 2048.

`libraw-model-survey.json` retains R1's twenty public CC0 RAW measurements
(raw.pixls.us IDs identify the public samples). `libraw-model-7s.json` retains
the same comparison on the fetched Sony ILCE-7S fixture. Errors are absolute
log2-gain differences: mean, p99 and maximum after pixel-centred bilinear
alignment. These are migration evidence, not quality acceptance thresholds.
The old executable remains only in ignored build-r3-validation/ as evidence.

`apple-model-7s.json` freezes the Release Apple outputs immediately before R3;
`apple-model-7s-debug.json` freezes Debug/ASan outputs using the retained
pre-deletion build-e4d-asan libraries and the old headers from 9eb0680.
The reference capture helper is in ignored build-r3-validation/freeze_asan.py.
Debug and Release differ slightly in model preparation/inference, so the test
selects the corresponding reference using NDEBUG. Each configuration must remain
byte-identical to its own pre-deletion output; cross-configuration identity is
not the CLI/ABI/Kit same-build contract.
raw_ciraw_test checks model identity, grid dimensions and SHA-256 of packed
little-endian float32 gain pixels on the same OS build. The numeric mean/min/max
are human-readable evidence. The source fixture is fetched by
scripts/fetch_test_fixtures.py; it is not copied here. A changed OS build or
system default decoder requires explicit evaluation before updating baselines.
No user photographs or metadata dumps are included.
