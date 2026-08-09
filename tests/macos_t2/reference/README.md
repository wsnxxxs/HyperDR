# Third-party reference files

**Nothing here is a fixture.** These files are not hashed, not frozen, and take
no part in the T2 decision rule. They exist for one job: when ImageIO does not
expose an ISO gain map for our own fixtures, files written by other pipelines
are what separate "Apple will not read the container our writer produces" from
"Apple only surfaces gain maps it wrote itself" from "this harness asks for the
gain map the wrong way".

`run_t2_local.sh` passes every image in this directory to
`diagnose_imageio.swift` after the fixtures, and warns when the directory holds
none.

## IMG_3841.HEIC — Apple's own writer

An iPhone capture. Verified with `HyperDR.exe inspect` before it was placed
here: `tmap` brand, `tmap` item, `dimg`, `altr`, ISO metadata present,
`gain_max` 2.5234, `alternate_headroom` 2.5234, `gamma` 0.8618.

It carries its original EXIF, which normally includes capture time and location.

## idg_a8d59bf1077d1452826f.jpg — Adobe Indigo, a conformant third-party writer

One of the 109 files in the frozen Indigo container audit
(`HyperDR_Model/reports/indigo-container-audit.json`), which records it as
`ok: true`, `iso_generic`, three channels, MPF present, gain map at image index
1, gamma 1.0 per channel. Its bytes carry `urn:iso:std:iso:ts:21496:-1` twice.

Read it with one caveat in mind: it is **JPEG/MPF** while our fixtures are
**HEIC**, so a difference between the two could come from the container format
rather than from conformance. The clean comparison would be a non-Apple HEIC
ISO gain map, which this project does not have. It still separates the
strongest hypotheses, which is why it is here.

Both files are git-ignored (`*.heic` / `*.jpg`, with an exception only for
`fixtures/`), so they travel only inside a hand-carried transfer bundle.
