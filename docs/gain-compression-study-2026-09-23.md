# Gain-map compression study — 2026-09-23

Implementation follow-up: Adaptive HEIC now uses fixed gain quality 95 at the
existing map resolution. The measurements below describe the preceding study;
the final delivery checks are recorded at the end of this document.

High-quality lossy HEVC at the original gain-map resolution is a reasonable
compatibility candidate. In this experiment its added brightness error was very
small. Halving the dimensions was substantially more damaging at gain edges.
This revises the earlier conservative position: preserving exact gain codes is
not, by itself, sufficient reason to require lossless delivery.

The subsequent [WSL source-image census](wsl-gainmap-comparison-2026-09-23.md)
supports investigating coding tools and level: all 847 Apple originals use
conventional lossy gain configurations. It also disproves a blanket grid/RExt
objection: all native ISO sources have grid gain, and all source gain streams
use monochrome RExt. No Apple-device outcome is implied by either study.

## Method

The local experiment `output/gain-compression-study/study.py` loads the shipped
libheif 1.23.1 and x265 DLLs via ctypes. It decodes existing gain planes, encodes
them as full-range 8-bit YCbCr 4:2:0 with neutral chroma, then decodes the result.
It follows the writer's 3072-pixel single-picture threshold and 2048-pixel grid
tiles. Every lossless control reproduced all gain codes exactly.

Three inputs were used:

- A 9504×6336 HDR photograph's existing Adaptive gain map (`DSC02120`), with
  2.30045 stops of gain range, gamma 1, and 4.904% nonzero gain codes.
- A newly exported 3000×2000 SDR city/aircraft photograph, with 2.19062 stops,
  gamma 0.4, and 1.719% nonzero gain codes.
- A synthetic 2048×512 map combining a ramp, alternating three-pixel bright
  bars, and seeded noise, using 4 stops and gamma 1.

The reference is the existing lossless gain plane, holding the decoded SDR
base fixed. For this project's zero-offset, shared-RGB gain model, if compression
changes the decoded gain in stops by `delta`, the relative brightness change is
`2^(w * delta) - 1`, where `w` is the display's gain weight. Results use `w=1`;
partial HDR headroom reduces this particular error, and SDR (`w=0`) removes it.
The gamma decoding is included: `delta = range * (new_code^(1/gamma) -
old_code^(1/gamma))`, with codes normalized to [0,1]. At gamma 1, a one-code
error corresponds to about 0.627% at 2.30045 stops or 1.093% at 4 stops.

The metric is added multiplicative brightness error, not Delta E, whole-image
fidelity to the original source, or a subjective visibility score. It applies
before additional display gamut mapping or clipping. Black base pixels remain
black. Reporting nonzero-gain pixels separately avoids hiding errors under
the large zero-gain regions. The edge subset includes pixels differing by more
than 16 codes from their left or upper neighbour.

For the half-size experiment, the encoded gain is reduced using a box average
and expanded with bilinear interpolation, retaining the same SDR base. This
tests a direct downscale policy, not every possible optimized small-map/base
pair. Apple interpolation may differ. Output files contain standalone gain
images, not complete Adaptive HDR containers suitable for a Photos test.

## Measurements

Sizes include the standalone gain-image container; they are not total photo
sizes. Error columns are absolute percentages of reconstructed brightness in
the subset that originally had nonzero gain.

| Input | Gain coding | Size KiB | Change vs lossless | Mean error | P99.9 error | Maximum error |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| HDR photo | Lossless | 774.7 | — | 0 | 0 | 0 |
| HDR photo | Q95, original dimensions | 862.6 | +11.4% | 0.0050% | 0.627% | 1.894% |
| HDR photo | Q90, original dimensions | 854.6 | +10.3% | 0.0067% | 0.627% | 1.894% |
| HDR photo | Q85, original dimensions | 841.7 | +8.7% | 0.0093% | 0.627% | 2.533% |
| HDR photo | Q80, original dimensions | 815.6 | +5.3% | 0.0154% | 0.627% | 3.682% |
| HDR photo | Q95, half width and height | 291.2 | −62.4% | 0.8781% | 45.456% | 172.816% |
| SDR photo | Lossless | 77.2 | — | 0 | 0 | 0 |
| SDR photo | Q95, original dimensions | 78.0 | +1.1% | 0.0047% | 0.588% | 1.363% |
| SDR photo | Q90, original dimensions | 74.5 | −3.4% | 0.0107% | 0.861% | 1.416% |
| SDR photo | Q85, original dimensions | 69.7 | −9.7% | 0.0201% | 0.964% | 1.533% |
| SDR photo | Q80, original dimensions | 61.6 | −20.2% | 0.0376% | 1.034% | 2.715% |
| SDR photo | Q95, half width and height | 33.6 | −56.4% | 0.4899% | 18.267% | 25.830% |
| Synthetic | Q95, original dimensions | 230.4 | −60.9% | 0.0032% | 1.081% | 1.093% |
| Synthetic | Q95, half width and height | 54.2 | −90.8% | 9.7067% | 64.500% | 103.565% |

Q100 and Q95 produced identical decoded codes and file sizes on all three
inputs. This is an observation about the current encoder and these inputs,
not a general quality equivalence. Neither setting is guaranteed lossless.

On the HDR photo's gain edges, mean brightness error was 0.0266% at full-size
Q95 versus 13.057% at half-size Q95. The former changed only 0.0468% of all
gain codes. Among originally zero-gain pixels, about 0.0000122% became brighter
by more than 1%; half-size Q95 increased that fraction to 0.1469%.

Near-lossless coding need not save space: the HDR map is already very sparse,
and its lossless form is smaller than the tested full-size lossy variants.
[x265's documentation](https://x265.readthedocs.io/en/stable/lossless.html)
explicitly notes that near-lossless encoding can exceed lossless bitrate.
The synthetic map's large saving must not be projected onto all photographs.

## Compatibility interpretation

All lossless controls signalled Main Still Picture (profile 3), level_idc 255
(Level 8.5), and PPS transquant bypass enabled. All lossy variants retained
profile 3, removed transquant bypass, and signalled ordinary Levels 3–5 according
to encoded dimensions. The HDR photo's full-size tiles changed from Level 8.5
to Level 5. These are actual bitstream changes, independently checked in
`output/gain-compression-study/signalling.py`.

Removing bypass and the unusual level requirement makes the stream a more
conventional decoder input. That supports a compatibility improvement as an
engineering inference; it does not prove an Apple-specific failure was fixed.
No iPhone or macOS decode/display test was performed in this experiment.

Lossy coding does not remove a gain grid. Even halving the 9504×6336 map leaves
4752×3168 pixels, which still exceeds the writer's single-picture threshold.
Eliminating that grid would require a separate resolution policy; its tradeoff
must not be credited to changing compression alone.

[Google's Ultra HDR guidance](https://developer.android.com/media/platform/hdr-image-format)
recommends starting with JPEG quality 85–90 and permits differently sized gain
maps. This supports lossy gain coding as normal practice, but JPEG and HEVC
quality numbers are not equivalent. Apple's
[WWDC24 guidance](https://developer.apple.com/videos/play/wwdc2024/10177/)
describes gain images as typically half the SDR image size; it neither requires
that size nor establishes the quality of downscaling this project's maps.

## Recommendation

For a compatibility-oriented default, the evidence favors original-resolution
gain maps encoded with high-quality lossy HEVC, starting at Q95. This preserves
sharp gain transitions while removing bypass and Level 8.5. Lossless remains
useful for numerical validation or an explicit precision mode, but final-image
quality should be judged after both base and gain decoding: a lossy base means
lossless gain alone never guaranteed a lossless delivered photograph.

Do not automatically halve maps solely to imitate a typical Apple size. The
observed edge penalty is much larger than the compression penalty. If device
testing identifies auxiliary grids as the actual problem, investigate a
bounded-resolution policy separately, with reconstruction error and gain-edge
checks rather than a global average alone.

This is a small, targeted study, not a general perceptual guarantee. An HDR
Photos A/B comparison remains necessary before claiming an iOS zoom fix.
Production defaults were not changed during the original analysis; Q95 was
subsequently implemented as described above. Detailed per-case JSON,
the experiment script, and generated gain images remain under
`output/gain-compression-study/`.

## Q95 implementation and delivery checks

The Adaptive HEIC gain encoder now uses fixed lossy quality 95, independently
of the user's base-image quality. Resolution, grid thresholds, neutral-chroma
4:2:0 format, auxiliary identifier and metadata remain unchanged. No new setting
was added. Existing output-resume fingerprints already include the executable
and codec DLL identity, so old encoded outputs are not considered current after
the executable changes.

The codec-enabled Release build and `codec_test.exe` passed. The existing
synthetic high-frequency gain probe measured mean absolute code error 0.148438
and maximum 1. Its previous exact-code assertion is now a bounded-error check
(mean at most 0.5 codes, maximum at most 3); the existing reconstruction checks
remain in place. Existing HEVC profile checks also reject Level 8.5.

Four complete CLI exports were compared with lossless controls generated by
the previous executable. All passed the converter's post-encode verification.
Independent parsing confirmed identical base coded-payload hashes and base
properties, identical tmap metadata, and unchanged gain dimensions, tiling,
auxiliary relationships and nclx properties. Every new gain hvcC/VPS/SPS retained
profile 3, every PPS had bypass disabled, and no gain stream used Level 8.5.

| Case | Encoded gain dimensions | Gain tiles | New level | Maximum code error | Mean gain-factor error | Maximum gain-factor error | Total file-size change |
| --- | --- | --- | --- | --- | --- | --- | --- |
| SDR city/aircraft photo | 3000×2000 | 1 | 5 | 1 | 0.000080% | 1.363% | +0.036% |
| 10-bit base synthetic grid | 4096×3072 | 4 | 5 | 1 | 0.000053% | 1.215% | +0.040% |
| Research CNN result | 1500×1000 | 1 | 4 | 1 | 0.001725% | 0.315% | −0.042% |
| 60 MP HDR photograph re-export | 9504×6336 | 20 | 5 | 3 | 0.000095% | 1.894% | +0.228% |

Gain-factor error is `abs(2^(decoded_new_stops - decoded_old_stops) - 1)`.
It isolates the changed gain with the same base and is not a perceptual score.
For zero-offset reconstruction it also gives relative HDR brightness error;
the AI path has nonzero offsets, so its row is explicitly a multiplier error.
Sparse maps make whole-image means small: among nonzero map codes, mean errors
were 0.00464%, 0.01809%, 0.00172%, and 0.03028% respectively. These samples
demonstrate the intended coding change, not universal error bounds or smaller
files. No Apple-device zoom test was performed.

Complete before/after files, CLI reports, independent inspection and comparison
script, and `comparison.json` remain under `output/gain-q95-delivery/`.
