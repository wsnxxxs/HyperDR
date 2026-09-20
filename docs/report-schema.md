# Report schema 11

What `--report` writes. The machine-readable JSON Schema is
[`schema/report.json`](../schema/report.json): it defines every required object,
field, type, enum, and nullable value in a schema-11 report. The emitter is
`modules/app/src/report.cpp`, and `report_test` checks emitted reports against
the schema. Update all three together whenever the report version or shape
changes.

## Contents

`--report` writes schema 11. Its `settings` block is generated from the settings
table, so it records every setting by its canonical name — not the handful someone
remembered to add — plus `output_depth`, the depth actually encoded (BT.2100 is
always 10-bit regardless of `--depth`). The top-level `raw_processing` block
records requested calibration files, auto bad-pixel mode, post-decode linear
gain and the black/WB policies for the run. Invalid requested calibration
files fail the conversion rather than silently appearing as applied.
The optional per-file `raw_white_balance` records `camera`, `camera-applied`,
`auto`, or `daylight`; an empty string means no RAW decode was reported (for
example a raster, skipped file or failure before rendering). It survives decode
cache hits. The optional per-file `raw_color_matrix` records where the camera
matrix came from: `embedded` (the file's own matrix; for a DNG, its whole
colour model, both calibrations interpolated at the as-shot white with any
ForwardMatrix, unless the DNG SDK would refuse that profile, in which case it is
LibRaw's choice of the file's ColorMatrix), `libraw` (LibRaw's per-model table),
`dcp` (the explicitly selected external camera profile),
or `none` (LibRaw has no matrix for the camera, so its colour is uncalibrated,
and the decode is also reported as degraded with `no_camera_matrix`); an empty
string follows the same rule as `raw_white_balance`, and it too survives decode
cache hits.
Each file carries flat result fields and `look`, `render`, and
`gain_map` objects. These record EV100 (or
`null`), selected/linear headroom, rendered peak, utilization, gamma, gain
percentiles, high-gain fractions, clipping, and local-weight diagnostics.
The global `settings.pop` and per-file input-domain
`render.wide_gamut_fraction` are also recorded.

## Input domain

Schema 8 adds `input_domain` and `input_headroom` to each file. `input_domain`
is one of `scene-referred`, `display-referred-sdr`, `display-referred-hdr`, or
`unknown`. It is the decoder's answer, not a guess from the file extension: an
Ultra HDR JPEG that fell back to its SDR primary reports
`display-referred-sdr`. A skipped or failed file reports `unknown` because it
never reached a decoder.

Read it first, because it decides what the rest of the record means. Only a
scene-referred file gets automatic exposure; an external DCP uses its recorded
baseline instead of scene-metered exposure. For ordinary RAW, `exposure_ev` is a decision
the renderer made about the scene; for the other two it is nothing but the
creative offset the caller asked for. Only a scene-referred file gets
content-selected headroom; a display-referred HDR file's `headroom_stops` is
its `input_headroom` capped by `--headroom`/`--headroom-max` and scaled by
`--gain-strength`. A display-referred SDR file has no measured input headroom,
but its output uses the requested range as a creative expansion budget, so its
reported `headroom_stops` can be non-zero while `input_headroom` remains 1.

For `unknown`, `input_headroom` is the schema-safe sentinel `1` and must not
be interpreted. Otherwise, `input_headroom` is the linear multiple of diffuse white the input's container
declared. It is 1 for both other domains. It is a property of the encoding
rather than a measurement, so an HDR file whose colour is described by an ICC
profile rather than by CICP reports 1 and the SDR domain: an ICC profile cannot
state a headroom, and rendering such a file faithfully beats inventing a range
for it.

## Geometry fields

Schema 8 retains the compatibility fields `target_*` / `decoded_*` and adds the
unambiguous aliases `requested_crop_*` / `delivered_crop_*`. The latter pair is
the geometry contract used by model sidecars, including odd/CFA-aligned crops.
It also records the per-file sensor raster, DefaultCrop request, actual decoded
dimensions, `decode_degraded`, and `decode_degradation_reasons`. This makes an
unapplied DefaultCrop visible instead of presenting an uncropped result as an
ordinary success; the converter also prints a `warning:` line for each degraded
file, and the panel raises it after a successful run. RAW resolution is not a
degradable export property: previews explicitly request LibRaw's fixed half-size
demosaic, while full exports preserve the input dimensions or fail. RAW inputs
are admitted up to 19008 x 12672 (240.8 MP), the A7R V 16-frame Pixel Shift
composite size.

`sensor_*` is the physical readout and is not rotated by the capture
orientation; `target_*` and `decoded_*` are. Compare `decoded_*` against
`target_*` only when `target_dimensions_applied` is true -- when a recorded
DefaultCrop is rejected, `target_*` is the request that was refused rather than
a geometry the decode delivered. `default_crop_present` distinguishes "no crop
recorded" from "crop applied". `decode_degradation_reasons` is a string array
for diagnostics and display only: new reasons may be added at any time, so no
consumer should branch on its contents. A DNG reports `dng_opcode_unsupported`
when its opcode lists require an operation the decoder does not apply, and
`dng_opcode_list_malformed` when a list does not parse.

## Headroom fields

The flat `files[].headroom_stops` is the actual rendered peak (and is written to
`alternate_headroom`). `render.headroom_stops` and `headroom_linear` are the
selected nominal target; `rendered_peak` and `headroom_utilization` are the
post-local-gain result. `gain_map.local_weight_mean` and
`gain_map.local_weight_p95` are serialized diagnostics.

### Export timing breakdown

`encode_ms` retains its aggregate meaning: encoding, verification and publication.
`codec_ms` measures the encoder; `verify_ms` measures release of render buffers
and output verification; `write_ms` measures the source-stamp check and atomic
publication. The three components sum to `encode_ms`. Skipped or failed files
retain zero for stages that did not complete.

## Colour LUT and output rendition

The additive `color_lut` block records the path, SHA-256, input/output space and
strength of the creative LUT. It is independent of `raw_processing.linearization_lut`.
Settings include `lut_input`, `lut_output`, `lut_strength` and `gain_map_output`.
`encoding: sdr-jpeg` has zero output headroom and no encoded gain map; direct
HLG/PQ outputs also have `gain_map_output: false`.

## Model identity

A run that used a native model reports four members beside `model_development`:

| member | meaning |
|---|---|
| `model_requested_id` | the id the command line named |
| `model_id` | the id that actually produced the gain |
| `model_version` | the frozen asset's version string |
| `model_inference_mode` | `not_run`, `pixel_only`, `exif_assisted` or `pixel_only_fallback` |
| `model_fallback_reason` | empty unless the mode is a fallback, then the fields that were missing |

`model_id` was the embedded asset's identity string in schema 8 and is now the
selected model's id, which is why the schema number moved. The requested and
effective ids are separate members because they differ on a fallback, and a
reader that only saw one of them could not tell a fallback from a result.

`settings.ai_model_id` replaces `settings.ai_model`: the value is an id from the
model table, not a path.


## External RAW DCP (schema 11)

`settings.raw_profile` records the requested DCP path. The per-file fields
below describe the profile actually used, including after a decode-cache hit:

| Field | Meaning |
|---|---|
| `raw_color_matrix` | `dcp` when the external profile supplies camera colour conversion |
| `raw_profile_name` | DCP profile name |
| `raw_profile_sha256` | SHA-256 of the profile file's contents |
| `raw_profile_camera` | Profile's UniqueCameraModel |
| `raw_profile_tone` | `profile` for an explicit curve, or `adobe-sdk-acr3` for the SDK default |
| `raw_profile_baseline_ev` | RAW baseline exposure plus DCP BaselineExposureOffset, in EV |

Without an applied external DCP, profile strings are empty and baseline EV is
zero; these are absence markers, not measurements of the default RAW look.
The baseline does not include the caller's additional exposure adjustment.
The reported tone source identifies the implemented SDK-style rendering, not
a claim that Lightroom's current Process Version has been reproduced.

A native-model DCP base reports `model_development: raw-dcp-v1`. The separate
`hyperdr.model-input/v1` descriptor carries `raw_profile_sha256` and
`development_recipe.id: raw-dcp-v1`; an external gain sidecar copies the hash
to `model_binding.source.raw_profile_sha256` and preserves that recipe.
Replay requires the same profile hash and recipe, preventing a gain prediction
for one DCP base from being applied to another.

Schema 11 also retains schema 10's encoded-gain reporting: API3-derived gain
ranges describe the encoded result; distribution statistics that were not
measured are omitted rather than copied from a different pre-JPEG gain grid.
