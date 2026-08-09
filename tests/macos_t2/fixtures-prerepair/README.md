# The pair macOS refused

**Not fixtures.** These take no part in the decision rule and are not listed in
`fixture_spec.json`. They are the exact bytes that gate T2 ran against on
2026-08-09, when macOS 26 ImageIO exposed no ISO gain map for either of them:

| file | sha256 | bytes |
|---|---|---|
| `gamma-1-control.heic` | `bd314f1c12507d7249162f1e777f73c81539e12696ebcc437efa65f18b345436` | 4194 |
| `gamma-2-probe.heic` | `2d44743efc0ecb38b4ab933ea7317af2fdcf2be4e40c54a148e26c26b4b6f984` | 4194 |

They were produced before `heif_tmap.cpp` learned to emit `dinf`, the `auxC`
auxiliary type, and the `auxl` reference, and they are kept so the next macOS run
is a controlled comparison rather than a single observation: `run_t2_local.sh`
passes them to the diagnostic alongside the current fixtures. If the current pair
is exposed and this pair is not, in one run on one machine, the repair is what
changed the outcome.

The three container changes were made together, so a passing run shows they
suffice; it does not show which one macOS requires. Separating them needs four
variants and is a different experiment.

Their provenance, including the manifest that recorded them as the frozen pair,
is in the commit that introduced the repair.
