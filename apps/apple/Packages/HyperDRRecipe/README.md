# HyperDRRecipe

Platform-independent recipe and parameter declarations: `Foundation` only, no
AppKit, UIKit or Photos. Minimum macOS 27 / iOS 27. The inspector, undo, the GPU
nodes and `PHAdjustmentData` all read the same table (p7-adjustments §2.2).

## Parameters (`Adjustments.all`, 34 declarations)

Groups appear in this order: HDR, Light, Color, Look, Detail (5 parameters here are
RAW-only plus `develop.temperature`/`develop.tint`, 6 in total); `local` is reserved
and empty. Scope: `whole` changes both renditions, `hdrOnly` only the gain above SDR
white (H1), `sdrOnly` only the base with gain compensation (H2).

| id | kind · range · step | default | domains / visible when | scope · cost |
|---|---|---|---|---|
| `hdr.enabled` | bool | on | all | hdrOnly · instant |
| `hdr.source` | choice (`HDRSource`) | per domain: `sdr`→expand, `rawEDR`→captured, `hdr`/`dual`→builtIn | all, HDR on | hdrOnly · inference |
| `hdr.model` | reference | `research-cnn-v1` | all, source is AI, ≥2 models | hdrOnly · inference |
| `hdr.strength` | 0…200 %, 1 | 100 % | all, HDR on | hdrOnly · instant |
| `hdr.range` | floatOrAuto 0.5…4 stops, 0.1 | auto (≤3 for generated HDR, C1) | all, HDR on | hdrOnly · instant |
| `hdr.expansionStart` | floatOrAuto 18…75 %, 1 | auto (25 % for expansion, C1) | all, source expands or is AI | hdrOnly · instant |
| `hdr.coverage` | 0…100 %, 1 | 60 % (C1) | all, source expands | hdrOnly · instant |
| `hdr.sdrRolloff` | 0…100 %, 1 | 0 % | `rawEDR`, `hdr`; HDR on | sdrOnly · instant |
| `tone.exposure` | −4…4 EV, 0.01 | 0 | all | whole · instant |
| `tone.contrast` | −100…100, 1 | 0 (engine multiplier 1) | all | whole · instant |
| `tone.highlights` | −100…100, 1 | 0 | all | whole · instant |
| `tone.shadows` | −100…100, 1 | 0 | all | whole · instant |
| `tone.blacks` | −100…100, 1 | 0 | all | whole · instant |
| `develop.temperature` | 2000…12000 K, 50 | `fromSource` | `rawEDR` | whole · redevelop |
| `develop.tint` | −150…150, 1 | `fromSource` | `rawEDR` | whole · redevelop |
| `color.warmth` | −100…100, 1 | 0 | `sdr`, `hdr`, `dual` | whole · instant |
| `color.tint` | −100…100, 1 | 0 | `sdr`, `hdr`, `dual` | whole · instant |
| `color.vibrance` | −100…100, 1 | 0 | all | whole · instant |
| `color.saturation` | −100…100, 1 | 0 | all | whole · instant |
| `look.lut` | reference | none | all | whole · instant |
| `look.enabled` | bool | on | all, LUT chosen | whole · instant |
| `look.strength` | 0…100 %, 1 | 100 % | all, LUT chosen | whole · instant |
| `look.input` | choice | `srgb` | all, LUT chosen | whole · instant |
| `look.output` | choice | `srgb` | all, LUT chosen | whole · instant |
| `look.film` | choice (`Adjustments.filmStocks`: 5 stocks in `filmFamilies`) | `none` | all | whole · instant |
| `look.filmStrength` | 0…100 %, 1 | 100 % | all, a film chosen | whole · instant |
| `look.filmExposure` | floatOrAuto −3…3 EV, 0.1 | auto (centre-weighted meter of the original) | all, a film chosen | whole · instant |
| `look.filmGrain` | 0…200 %, 1 | 100 % (the stock's grain on 35 mm) | all, a film chosen | whole · instant |
| `look.filmHalation` | 0…200 %, 1 | 100 % (the stock's own) | all, a film chosen | whole · instant |
| `look.filmAntihalation` | bool | on (off: the layer removed, as CineStill) | all, a film chosen | whole · instant |
| `develop.luminanceNR` | 0…100 %, 1 | `fromSource` | `rawEDR` | whole · redevelop |
| `develop.colorNR` | 0…100 %, 1 | `fromSource` | `rawEDR` | whole · redevelop |
| `develop.sharpness` | 0…100 %, 1 | `fromSource` | `rawEDR` | whole · redevelop |
| `develop.lensCorrection` | bool | on | `rawEDR` | whole · redevelop |

`Adjustments.visible(in:)` filters by input domain; `Adjustments.visible(in: Recipe)`
also evaluates `visibleWhen` against the recipe's values and defaults. Capabilities
(`CIRAWFilter.is…Supported`, `HyperDR.aiModels >= 2`) are carried as strings and
resolved by the app; they are not evaluated here.

Localization keys are derived, never stored: `ctrl.<id>.label`, `ctrl.<id>.help`,
`undo.<id>`, `<group>`, and `<parameter>.<option>` (`hdr.source.capturedExpand`).

## Units and the engine

Recipes and the inspector use the declared units above. Each numeric declaration states
its own `scale`, and `ParameterDeclaration.engineValue(_:)` applies it; the readout
`format` never decides an engine unit:

| scale | engine receives | parameters |
|---|---|---|
| `direct` | the declared value | `tone.exposure` (EV), `hdr.range` (stops), `develop.temperature` (kelvin), `develop.tint` (−150…150, CIRAWFilter's `neutralTint`) |
| `hundredth` | value ÷ 100 | percent controls, and signed levels such as `tone.shadows`, `color.saturation` (−1…+1) |
| `contrast` | `1.6^(value/100)` | `tone.contrast`: 0 → 1, +100 → 1.6, −100 → 0.625 (C1 calls the default 1, the inspector shows 0) |

RAW `develop.tint` is the case that makes the split necessary: it reads as a signed
number like `tone.shadows`, but CIRAWFilter takes it unchanged.

The automatic range is capped at `Adjustments.generatedRangeCeiling` (3 stops) only for
HDR that HyperDR generates itself — the `sdr` expansion and `rawEDR` (C1). `hdr` and
`dual` sources already have HDR, so an automatic range must not go below the source's
own headroom and may reach the declared 4 stops; Render resolves that. The analytic
expansion's automatic start is `Adjustments.automaticExpansionStart` (25 %, C1).

## Recipe v1

```json
{"hdrSource":"captured","inputDomain":"rawEDR","look":{"contentHash":"sha256:…","name":"Kodak 2383"},"values":{"tone.exposure":0.3},"version":1}
```

- Only values that differ from the declared default are stored, keyed by id.
- The envelope carries the input domain (defaults depend on it), the HDR source and
  the LUT reference. `hdr.source` and `look.lut` never appear in `values`; read them
  through `hdrSource`, `look` or `value(for:)`.
- A LUT is identified by content hash (and, optionally, a security-scoped bookmark),
  never by a path.
- Values for ids this build does not know are kept verbatim and written back, so a
  newer recipe survives a round trip. `ParameterValue` is a small JSON tree, so an
  unknown object or array from a newer build round-trips instead of failing the whole
  recipe. Numbers are `Double`: integers above 2^53 lose precision. Unknown top-level
  keys are not preserved.
- `encoded()` writes sorted keys, so the same recipe always produces the same bytes.
- `adjustmentData()` returns `formatIdentifier` `com.hyperdr.HyperDR.recipe`,
  `formatVersion` `"1"` and the bytes, ready for `PHAdjustmentData` without importing
  Photos; `Recipe(adjustmentData:)` restores it.

## Tests

Seven checks in `Tests/HyperDRRecipeTests`: the declaration table (count, unique ids,
defaults inside ranges, options and derived keys), recipe round trip and stable JSON,
unknown ids surviving a round trip, structure-valued unknown ids, domain/condition
filtering, the engine scale of each numeric declaration, and the generated-HDR range
ceiling. Determinism of actual rendering is Render's business.
