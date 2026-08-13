# Report schema 7

What `--report` writes. The machine-readable JSON Schema is
[`schema/report.json`](../schema/report.json): it defines every required object,
field, type, enum, and nullable value in a schema-7 report. The emitter is
`modules/app/src/report.cpp`, and `report_test` checks emitted reports against
the schema. Update all three together whenever the report version or shape
changes.

## Contents

`--report` writes schema 7. Its `settings` block is generated from the settings
table, so it records every setting by its canonical name — not the handful someone
remembered to add — plus `output_depth`, the depth actually encoded (BT.2100 is
always 10-bit regardless of `--depth`). The top-level `raw_processing` block
records the calibration files, auto bad-pixel mode, and sensor digital gain used
for the run. Each file carries flat result fields and `look`, `render`, and
`gain_map` objects. These record EV100 (or
`null`), selected/linear headroom, rendered peak, utilization, gamma, gain
percentiles, high-gain fractions, clipping, and local-weight diagnostics.
The global `settings.pop` and per-file input-domain
`render.wide_gamut_fraction` are also recorded.

## Geometry fields

Schema 7 retains the compatibility fields `target_*` / `decoded_*` and adds the
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
consumer should branch on its contents.

## Headroom fields

The flat `files[].headroom_stops` is the actual rendered peak (and is written to
`alternate_headroom`). `render.headroom_stops` and `headroom_linear` are the
selected nominal target; `rendered_peak` and `headroom_utilization` are the
post-local-gain result. `gain_map.local_weight_mean` and
`gain_map.local_weight_p95` are serialized diagnostics.
