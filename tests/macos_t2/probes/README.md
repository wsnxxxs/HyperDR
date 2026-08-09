# Attribution probes

**Not fixtures.** Nothing here is listed in `fixture_spec.json` and nothing here
enters the decision rule. These files exist so that a run says *which property*
macOS is reacting to, instead of producing another isolated observation.

## What three runs established

| run | fixtures | outcome |
|---|---|---|
| 2026-08-09 14:48Z | 8×4, no container repair | refused |
| 2026-08-09 15:34Z | 8×4, `dinf` + `auxC` + `auxl` added | refused |
| 2026-08-09 16:16Z | 8×4, plus `clap` repeated onto the tmap | refused |

The third run also carried ordinary-size files, and both were read — including
`normal-512x384-prerepair.heic`, which has **none** of the container repairs. So
the repairs were never what macOS required, and the refusal belonged to the
fixture geometry: below 64 pixels in either dimension an image is coded as a
padded 64×64 HEVC frame and cropped back by an essential `clap`.

The fixture pair is now 128×128 over a 64×64 gain map, with no `clap` anywhere.

## What the fourth run is for

The fixtures are no longer the question — they are expected to be read, and the
run should reach the frozen decision rule for the first time. These files stay
as controls that the machine still behaves as it did:

| path | expectation | if violated |
|---|---|---|
| `../fixtures-prerepair/*` | absent — 8×4, no repair | the machine changed, not the file |
| `tiny-8x4-auxrepair-only.heic` | absent — 8×4, aux repair only | same |
| `normal-512x384-prerepair.heic` | present — ordinary size, no repair at all | same |
| `normal-512x384-repaired.heic` | present — ordinary size, repaired | same |
| `../reference/*` | present — Apple and Adobe captures | the diagnostic itself is suspect |

The two 8×4 controls are what keeps "the fixture geometry was the problem" a
measurement rather than an assumption: they have to keep failing in the same run
where the 128×128 pair succeeds.

The container changes made after the first two runs — `dinf`, the `auxC`
auxiliary type, the `auxl` reference, and repeating transformative properties —
are retained as specification conformance, not as a fix for anything observed.
