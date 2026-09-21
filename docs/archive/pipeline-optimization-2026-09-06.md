# Interactive image pipeline optimization — 2026-09-06

The editor now coalesces continuous slider input into one active request and its
latest pending state. Pointer drags request a 640-pixel draft; release requests
the viewport tier immediately after the active frame. Keyboard changes request
a refined frame directly. `store.previewTiming` records request, presentation
and input-to-animation-frame elapsed time, geometry and response bytes. This
marks browser presentation scheduling, not physical display scanout.

## Implemented

- A native `preview-worker` accepts JSON argument arrays on stdin and returns
  length-framed packets on stdout. It retains two decoded resolutions and RAW
  source measurements. Superseded work terminates the worker; the next request
  starts it again. Converter identity changes restart it, and 90 idle seconds
  retire it. `HYPERDR_PREVIEW_WORKER=0` retains the file-based diagnostic path.
- Manual SDR and scene rendering retain source/setting-dependent preparation
  while strength changes recompute quantization with the original arithmetic.
  RAW base RGB and its pre-chroma luminance are retained, so cached statistics
  and pixels follow the original full-resolution formulas. All other reflected
  settings invalidate that preparation. Model predictions and their neutral
  base are retained across strength and post-model adjustments.
- The worker emits HYPREV2: aligned float32 base plus monochrome encoded gain,
  gamma, offsets and display weight. WebGPU and WebGL interpolate encoded gain
  before decoding it, matching native reconstruction. The editor can identify
  an existing base and receive only the gain payload; phone broadcasts stay
  self-contained. Existing CLI preview-frame files stay HYPREV1. The working
  tree's sRGB-limited path retains native full-plane reconstruction.
- Base GPU textures and the browser display copy are reused when their pixel
  identity and dimensions match; gain masks still invalidate on each new frame.
  Histograms sample native linear pixels at a maximum edge of 320; an exact
  full-size CPU reconstruction remains available for the compatibility path.
- Source statistics now use a 512-edge grid of normalized image coordinates,
  replacing resolution-dependent flattened strides. Source-analysis disk cache
  version 2 rebuilds the earlier samples. Fine gain/environment processing
  retains its existing algorithms; RAW half-size decoding and image reductions
  can still cause preview/export differences. This does not make those outputs
  pixel-identical.
- Resize columns precompute bilinear coordinates once for reuse by all rows.
  Export reports retain aggregate `encode_ms` and add `codec_ms`, `verify_ms`
  and `write_ms`. The benchmark reader now consumes the current `files` array
  and excludes skipped/failed conversions from successful timing samples.

## Measurements

Release MSVC 19.44, existing enlarged sunset fixture `scaled-photo.png`, one
warm-up and five measured strength changes per size (0.4 through 0.8). Both
paths use the same newly built renderer and warmed disk decode cache. The CLI
column includes process startup, full HDR reconstruction and packet file I/O;
the worker includes pipe transfer to Python. Neither includes HTTP or browser
presentation. This compares delivery paths, not an old/new renderer benchmark.

| Maximum edge | File CLI median | Worker median | Full v1 packet | Full v2 packet | Unchanged-base response |
| --- | ---: | ---: | ---: | ---: | ---: |
| 960 | 121.24 ms | 61.74 ms | 14.08 MiB | 7.63 MiB | 0.59 MiB |
| 2048 | 269.40 ms | 165.72 ms | 64.03 MiB | 34.68 MiB | 2.67 MiB |

The base planes are byte-identical to fresh CLI renders. JavaScript reconstruction
of the compact packets differs from the C++ float reference by at most
7.16e-7 per linear channel in these photographs. GPU output readback on a
synthetic nontrivial gamma/offset grid has maximum encoded-channel differences
of 0.001969 (8-bit WebGL SDR output) and 0.000973 (half-float WebGPU output).
These include output quantization and are not byte-identical GPU claims.

A real browser pointer drag produced seven draft frames followed by a refined
960-pixel frame. Warm draft responses were about 268 KiB. Timing varied under
concurrent local work, so the isolated medians above are the performance record.

Local scripts, measurements, packets and screenshots are under ignored
`build-core/pipeline-qa/` and `build-core/pipeline-*-qa.js`.

## Validation

- 32 core CTest checks and 3 native schema/curve integration checks passed.
- 167 existing panel Python checks passed (1 existing skip); the added real
  child-process regression passed reuse, cancellation and subsequent recovery.
- Frontend module parsing, history, HDR configuration, scheduler, packet/delta,
  role wiring and translation checks passed.
- Prepared SDR/scene renders retain fresh base and gain pixels at strength 0,
  0.001, 0.4, 0.8 and 1. The synthetic reference-statistics check agrees at
  640 and 1280 pixels. Native model base comparisons passed after strength and
  brightness changes, including returning to an earlier brightness.
- Chromium exercised real WebGL/WebGPU shaders, extended-float readback, photo
  display, continuous pointer input and release refinement.
- Adaptive HEIC, Ultra HDR JPEG, PQ/HLG HEIC and PQ/HLG AVIF exports self-verified.
  Their timing components sum to the aggregate encoding-stage measurement.
- The committed core also builds in an isolated source snapshot, without
  incorporating the workspace's pre-existing gamut or icon changes.

Original-camera RAW and physical HDR-display visual acceptance were not run;
synthetic scene-linear fixtures and GPU float readback do not substitute for
those checks.
