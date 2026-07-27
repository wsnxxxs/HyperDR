# HDR validation record

Record one row/set of values for each representative ARW. Keep source ARWs and generated HEICs outside Git; retain hashes when privacy permits.

| Field | Value |
|---|---|
| HyperDR commit / build | |
| Look / contrast / vibrance | photographic / 1.08 / 0.12 |
| Headroom maximum / selected / actual | |
| Rendered peak / utilization | |
| Gain gamma / range / p95 | |
| Local weight mean / p95 | |
| ARW scene | daytime diffuse / strong highlight / high ISO night |
| Capture metadata (ISO / shutter / aperture) | |
| Highlight recovery mode | blend / reconstruct / clip / unclip |
| `inspect` result | |
| `verify` result | |
| HEIC SHA-256 | |
| iPhone model / iOS version | |
| Transfer path | AirDrop / Files / other |
| Photos HDR expansion | pass / fail |
| SDR fallback | pass / fail |
| Highlight roll-off / colour artifacts | pass / fail / notes |
| Dark-region gain pumping | pass / fail / notes |
| Metadata | pass / fail |
| Edit retained HDR | pass / fail |
| Share retained HDR | pass / fail / flattened |
| Notes | |

For a manual headroom override, record the requested value and confirm it is within `0..--headroom-max`. In schema 6, flat `files[].headroom_stops` is the actual rendered peak and `render.headroom_stops` is the strength-adjusted target; peak calibration should keep them within 0.15 stop on qualified highlight scenes. Also reject an unexplained `decode_degraded`; its reason must match an intentional validation condition.
