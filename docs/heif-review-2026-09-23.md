# HEIF review verification — 2026-09-23

The supplied September 22 review correctly identified RExt signalling in
10-bit HEIC output and full-resolution, lossless gain maps. It did not establish
that grid gain maps or lossless coding cause iOS Photos zoom failures.

The subsequent [WSL source-image census](wsl-gainmap-comparison-2026-09-23.md)
finds grid gain maps in all 459 native ISO Apple originals and monochrome RExt
gain in all 847 originals. Thus the categorical claims about Apple not using
grid or RExt gain maps are contradicted by the actual source files. Lossless
coding and Level 8.5 remain unproven compatibility hypotheses.

The subsequent [compression experiment](gain-compression-study-2026-09-23.md)
measures the tradeoff directly: full-resolution Q95 caused very small added
brightness error and removed bypass/Level 8.5, while halving map dimensions
produced much larger edge errors. Its recommendation supersedes the provisional
decision below to retain lossless pending evidence. A later implementation
adopted fixed Q95 gain coding; the repair section below records the earlier
Main10 change and its then-current lossless gain behavior.

## Findings

| Claim | Verification | Action |
| --- | --- | --- |
| 10-bit Adaptive bases and PQ/HLG HEIC use RExt instead of Main10 | Confirmed in the encoder dependency and saved Adaptive/PQ samples. | Configure x265 to generate Main10 directly and check generated parameter sets. |
| VPS says Main while SPS says RExt | False for the supplied samples: hvcC, VPS, and SPS all say profile 4. | Correct the review; no inconsistency patch. |
| Every ordinary Adaptive rendition export has a full-resolution gain map | Confirmed for RAW, SDR, and HDR. AI/external-gain paths may retain their supplied grid size. | Correct stale code/documentation descriptions. |
| Gain maps larger than 3072 pixels are grids | Confirmed. | Preserve the existing precision policy pending device evidence. |
| Gain-map HEVC is lossless | Confirmed by the encoder setting and PPS bypass flag. Saved gain parameter sets also signal level 255. | Record a device-validation gap; this alone does not demonstrate decoder failure. |
| Apple never uses grid gain maps | Contradicted by the subsequent WSL census: 476 original Apple gain grids, including every native ISO sample. | Do not reject grids solely because of their item type. |
| Apple never supports lossless gain maps | Not established by sources or local device results; the WSL originals use conventional lossy configurations. | Test the lossless/Level 8.5 difference on the affected device. |
| Two HDR split implementations must be identical | They share shoulder/headroom semantics but deliberately differ in spatial packaging. | Add narrowly scoped cross-references without changing the frozen model recipe. |

## Evidence and corrections

The saved files under `output/pipeline-review-20260922/` were re-read by walking
every hvcC property and removing NAL emulation-prevention bytes before reading
VPS/SPS profile-tier-level. The local `recheck_ptl.py` records this check.

| Saved output | Base hvcC / VPS / SPS profile | Gain hvcC / VPS / SPS profile |
| --- | --- | --- |
| `adaptive/test_big-hyperdr-hyperdr.heic` | 4 / 4 / 4 | 3 / 3 / 3 |
| `adaptive10sdr/test_big-hyperdr.heic` | 4 / 4 / 4 | 3 / 3 / 3 |
| `adaptive8/test_big-hyperdr.heic` | 3 / 3 / 3 | 3 / 3 / 3 |
| `pq/test_big-hyperdr.heic` | 4 / 4 / 4 | — |

The original `sps_flags.py` and `pps_flags.py` iterate property associations
with a stride of two and consequently skip properties. In addition,
`sps_flags.py` guesses extension flags from the final nine RBSP data bits
instead of parsing SPS syntax. It cannot justify rewriting a profile on the
assumption that no extension tools are present. Fixed-length PTL fields also
do not make a raw byte patch sufficient: changed RBSP bytes can change NAL
emulation-prevention bytes and lengths.

The installed libheif headers report 1.23.1. Its
[x265 plugin](https://github.com/strukturag/libheif/blob/v1.23.1/libheif/plugins/encoder_x265.cc)
sets the still-picture frame count before applying custom `x265:` parameters.
[x265's parameter parser](https://github.com/videolan/x265/blob/master/source/common/param.cpp)
accepts `total-frames`; its
[profile selection](https://github.com/videolan/x265/blob/master/source/encoder/level.cpp)
uses frame count and keyframe interval to choose RExt for an intra-only 10-bit
stream. The report's blanket claim that encoder parameters cannot solve this
is therefore incorrect.

[Apple's HEIF support article](https://support.apple.com/en-us/116944)
discusses lower-resolution iCloud viewing in the context of upgrading old
operating systems. It does not document a modern Photos zoom failure for these
particular HEVC features. Apple's
[WWDC24 HDR guidance](https://developer.apple.com/videos/play/wwdc2024/10177/)
also recommends 10-bit PQ HEIF for edited HDR images; 10-bit HEIF itself is not
an unsupported format. Neither source supplies the claimed zoom-path causal
chain.

Full-resolution gain is an explicit fidelity choice in this pipeline. A gain
derived from edited endpoints can contain sharp spatial changes; a comment
about a different low-frequency development grid is not proof that downsampling
this map is harmless. Lossy quality 95–100 is likewise not a guarantee that
zero-gain codes or the base/gain compensation survive unchanged.

## Repair

The 10-bit Adaptive and PQ/HLG writers set `x265:total-frames=0`,
`x265:keyint=250`, and `x265:repeat-headers=1`. Each image or tile still feeds
one frame to its encoder. The first two settings avoid the still/intra-only
profile selection; the third retains parameter-set output for libheif to
collect into hvcC. Without it the experiment failed with `Invalid image size`.
The encoder creates the complete Main10 parameter sets, so no post-encode
profile relabelling or container offset repair is needed.

The 8-bit base, lossless gain coding, map resolution, and container graph keep
their existing behaviour. Cross-references between the HDR split implementations
document their shared tone semantics and intentional sampling differences.

Independent post-fix parsing of the generated Adaptive 10-bit and PQ files,
including a 4096×3072 PQ grid, finds profile 2 and compatibility `0x20000000`
in hvcC, VPS, and SPS. The 8-bit Adaptive sample remains profile 3 with
compatibility `0x70000000`; gain parameter sets retain their original profile
and level. Generated samples are local outputs under
`output/profile-main10-check/`, not checked-in photographs.

Validation passed with the codec-enabled Release build: `codec_test.exe`
exercised PQ/HLG, Adaptive 8/10-bit, single images, a 3200×48 HDR-source grid,
gain preservation, and decode/reconstruction checks. Its existing cases now
also assert the expected hvcC profiles. CLI `verify` passed for the generated
4096×3072 PQ grid and Adaptive 10-bit single image. The independent parameter-set
inspection above checks VPS/SPS as well as the configuration record.

## Remaining device check

Local libheif/libde265 decode and structural tests establish local correctness,
not Apple display behaviour. On an HDR iPhone, compare 8-bit Adaptive,
10-bit Adaptive, PQ, and HLG outputs at fit-to-screen and above 100% zoom.
Include a picture above the 3072-pixel gain-grid threshold and record device,
OS, dimensions, HDR continuity, and full-resolution detail. The existing
[macOS T2 probe notes](../tests/macos_t2/probes/README.md) record readable
512×384 images and rejected tiny 8×4 fixtures; they do not establish that the
current full-resolution auxiliary grids pass. The T2 overview still lists a
later fixture pass report as pending. No iPhone device result was produced by
this Windows review.
