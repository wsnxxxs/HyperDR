# LUT colour-space sources

The append-only IDs and indices live in `LUTSpace`. Camera/scene inputs are
RAW-only; display Rec.2020 uses gamma 2.4 and is available on every input.
Transfer functions are mirrored in `AdjustmentReference.swift` and
`Shaders/Adjustments.metal`. Scene exposure precedes the input transform.

Primary conversion matrices use normalized-primary matrices derived from xy
chromaticities and rounded to eight decimals. AP1 uses its D60 white and a
Bradford adaptation to D65 before conversion to Display P3. The existing
HLG/PQ matrices retain their previous precision.

Sources for the added spaces:

- [Fujifilm F-Log datasheet](https://dl.fujifilm-x.com/support/lut/F-Log_DataSheet_E_Ver.1.0.pdf), Ver.1.0: piecewise linear/log10; F-Gamut equals Rec.2020.
- [Fujifilm F-Log2C datasheet](https://dl.fujifilm-x.com/support/lut/F-Log2C_DataSheet_E_Ver.1.0.pdf), Ver.1.0: F-Log2 transfer; F-Gamut C red (0.7347, 0.2653), green (0.0263, 0.9737), blue (0.1173, -0.0224).
- [Apple Log Profile white paper](https://download.developer.apple.com/Developer_Tools/Apple_Log_profile/Apple_Log_Profile_White_Paper.pdf), September 2023: quadratic toe, logarithmic upper branch; Rec.2020 primaries. Values below the specified minimum reflectance map to zero.
- [Nikon N-Log specification](https://download.nikonimglib.com/archive4/zMDhS00ZuoyY0502OFd16BeF1X67/N-Log_Specification_%28En%2901.pdf), Ver.1.0.0: cube-root/log transfer in 10-bit code units; Rec.2020. The cube root is signed for negative scene values.
- [DJI D-Log / D-Gamut white paper](https://dl.djicdn.com/downloads/DJI_Ronin_4D/X9_D_Log_D_Gamut_Whitepaper_I.pdf), February 2022: native-EI transfer (no camera-specific clipping), D-Gamut xy primaries.
- [Canon Log Gamma Curves white paper](https://www.usa.canon.com/content/dam/canon-assets/white-papers/pro/white-paper-canon-log-gamma-curves.pdf), November 2018: revised Canon Log 2 full-range formula; scene reflection is divided by 0.9, as with our Canon Log 3 implementation. Uses the existing Cinema Gamut matrix.
- [Blackmagic DaVinci Wide Gamut / Intermediate](https://documents.blackmagicdesign.com/InformationNotes/DaVinci_Resolve_17_Wide_Gamut_Intermediate.pdf), August 2021, Ver.1.1: corrected green x=0.1682; Intermediate linear/log2 transfer.
- [ACEScct specification](https://docs.acescentral.com/encodings/acescct/): AP1/D60 and the specified linear toe/log2 transfer.

LUT automatic exposure uses the same centre-weighted log-luminance median and
bracketed secant solver as film metering. Cache identity includes the fixed
source identity, LUT content hash and both spaces; strength is absent. The
rendered trials use the full-strength LUT and no user light/colour edits.
The target is the camera's unedited display rendition, so subsequent light
edits keep their intended effect. This matches film exposure's semantics.
