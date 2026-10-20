# HEIF output sink memory (2026-10-20)

The container probe uses a 9568 × 6376 (61,005,568 pixel) grid with 247
synthetic 256 KiB IDR samples. The IDR framing is valid, but the padded samples
are deliberately not decodable HEVC. This isolates container assembly from VT
and the input/render caches; it is not a photograph export memory estimate.

On the local Apple Silicon Mac, fresh processes measured `TASK_VM_INFO`'s
`ledger_phys_footprint_peak`:

| Route | Peak bytes | Peak MiB |
| --- | ---: | ---: |
| Original writer at `13752790`, vector then atomic file write | 131,957,288 | 125.84 |
| Sink directly to file | 67,158,520 | 64.05 |

Both files contain 64,762,376 bytes. The reduction is 64,798,768 bytes
(61.80 MiB, 49.1%): approximately one complete compressed output. The sample
sequence still lives until assembly ends. Only metadata and the stream buffer
are added by the sink. `ftyp`/`meta`/`iloc` lengths and offsets are computed
before emission, so neither reserving file space nor seeking back is needed.

For a real, compressible gradient through `capi_package_rows_test stream 29760
64 adaptive` (2048 × 29760, E5 frame readback included), the process peaks were
24,085,272 → 24,249,136 bytes. Here the 512-row encoding slab and VT dominate;
this change does not promise a lower process peak for every image.

The standalone source is `tests/quality/heif_sink_memory.cpp`. From the checkout
root, after a native build:

```sh
mkdir -p build/tmp
clang++ -std=c++20 -O2 \
  '-DHYPERDR_HEIF_FIXTURES="modules/container/tests/fixtures/heif_writer"' \
  -Imodules/container/include -Imodules/foundation/include \
  tests/quality/heif_sink_memory.cpp \
  build-native/modules/container/libhyperdr_container.a \
  build-native/modules/foundation/libhyperdr_foundation.a \
  -framework CoreFoundation -o build/tmp/heif-sink-memory
build/tmp/heif-sink-memory
```

Define `HYPERDR_HEIF_VECTOR_OUTPUT` to compare the retained vector adapter.
For the original baseline, additionally compile the old `heif_writer.cpp` from
`13752790` with `-Imodules/container/src`; its definitions replace that archive
member. Measurements should be made in separate fresh processes.
