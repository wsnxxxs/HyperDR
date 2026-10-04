# Reproducing the patent research comparisons

This is a bounded research experiment, not a production encoder or a claim of
patent novelty. Read the [Chinese assessment](../patent-deep-research-2026-10-04.md)
for definitions and limitations. The product source baseline is `4795f81`.

`probe.cpp` calls the actual core packager and decoder. All four main policies
use the same per-image metadata range and 256 gain codes. The exhaustive search
keeps production's repair mask and the retained pixels' gain codes. It minimizes
SDR squared error on that mask subject to the pixel HDR tolerance. It is a new
research baseline, not a previously published prior-art document.

The fifth policy appears only on a one-pixel counterexample and searches gain
codes while retaining the original SDR. Six synthetic fixtures and one private
photo produce 29 CSV rows. Nothing measures final lossy HEVC/JPEG coding,
bitrate, perceptual visibility, or physical displays.

Build with the existing Windows core build:

```powershell
cmake --build build-core --config Release --target rendition_test --parallel 6
cmake -S docs/patent-research-2026-10-04 -B output/patent-deep-research/build -A x64
cmake --build output/patent-deep-research/build --config Release --parallel 6
# Synthetic comparisons only:
& output/patent-deep-research/build/Release/patent_probe.exe
```

For the existing private `IMG_0017` photo, NumPy and a codec-enabled CLI are also
needed. `prepare_photo.py` reads the original ISO offsets and requests direct
SDR/HDR float endpoints using the Ultra HDR preview path. Adaptive preview
already packs and reconstructs a monochrome map and must not be used to prepare
the inputs for this comparison.

```powershell
python docs/patent-research-2026-10-04/prepare_photo.py --source output/dual-rendition-validation/IMG_0017.heic --executable build-release/Release/HyperDR.exe --output output/patent-deep-research/IMG_0017-pair.bin | Set-Content output/patent-deep-research/photo-input.json -Encoding utf8
& output/patent-deep-research/build/Release/patent_probe.exe output/patent-deep-research/IMG_0017-pair.bin | Set-Content output/patent-deep-research/results.csv -Encoding utf8
```

The recorded input-generating CLI was built on September 24. It only prepares
the endpoints; the packager evaluated by the probe is the current core library
rebuilt on October 4. `photo-input.json` records the photo, CLI and float-input
hashes. `public-state.json` records anonymous public-repository reads, not an
assertion that no other version was ever published. Photos and binary pixels
remain in ignored `output/` and are not included in this research attachment.

CSV percentages are percentages, not fractions. SDR changed area uses the
largest per-pixel linear RGB difference and a threshold of `1/255`. HDR relative
error uses the target pixel's peak RGB channel with a `1e-5` floor; near-black
relative maxima should be interpreted with the absolute errors. The HDR
classification threshold is `0.001*peak+0.00001`; it is not a production output
quality guarantee. MSE averages all linear RGB channel samples.
