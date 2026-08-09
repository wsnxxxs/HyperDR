# Attribution probes

**Not fixtures.** Nothing here is listed in `fixture_spec.json` and nothing here
enters the decision rule. These files exist so that one macOS run answers which
property of a file macOS is reacting to, instead of producing another isolated
observation.

Two macOS runs have now shown a refusal, both on 8×4 files:

- 2026-08-09 14:48Z: the pre-repair pair — no `dinf`, no `auxC`, no `auxl`.
- 2026-08-09 15:34Z: the aux-repaired pair — all three present, still refused.

So those three absences were real but not the whole cause. The 8×4 fixtures
carry a second defect that ordinary-size output does not: an 8×4 image is coded
as a padded 64×64 HEVC frame and cropped back by an essential `clap`, and the
tmap item did not repeat that `clap`, so the derived item claimed 64×64 while
the base displayed 8×4. `heif_tmap.cpp` now repeats transformative properties
onto the tmap. **No ordinary-size file of this writer has ever been shown to
macOS.**

The five cells, all produced offline from the same writer sources:

| cell | file | size path | dinf/auxC/auxl | tmap repeats clap |
|---|---|---|---|---|
| A | `../fixtures-prerepair/gamma-2-probe.heic` | 8×4, padded + clap | no | no |
| B | `tiny-8x4-auxrepair-only.heic` | 8×4, padded + clap | yes | no |
| C | `../fixtures/gamma-2-probe.heic` | 8×4, padded + clap | yes | yes |
| D | `normal-512x384-prerepair.heic` | 512×384, no padding | no | n/a |
| E | `normal-512x384-repaired.heic` | 512×384, no padding | yes | n/a |

A and B are already known to be refused, and they are carried anyway: a control
that reproduces its known outcome in the same run is what makes the new cells
readable.

How to read the `ISOGainMap` lines:

- E present, C absent → the ordinary path was always fine and the 8×4 fixture is
  the problem; rebuild the fixtures at a size that avoids the padding path.
- C and E both present → the repairs are what macOS needed; T2 proceeds.
- C present, E absent → something in the ordinary path alone is wrong, which
  would be a surprise worth stopping for.
- C and E both absent, D and the third-party references behaving as before →
  neither repair is sufficient and the remaining difference is elsewhere;
  hand-rolled tmap injection versus a library that writes it natively becomes
  the question.

D exists to keep the ordinary path from being read off a single file: if D and E
differ, the difference is the repair, not the size.
