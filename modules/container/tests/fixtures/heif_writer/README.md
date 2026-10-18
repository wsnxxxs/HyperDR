# HEIF writer fixtures

All content here was generated for HyperDR on 2026-10-18; synthetic content is
CC0. No photograph or third-party sample was used.

`params8.txt` / `params10.txt` each contain three hexadecimal lines: VPS, SPS,
PPS (no start codes or length prefixes). They were captured from HyperDR's V1
VideoToolbox encoder, quality 90, a single zero-filled 512x512 4:2:0 tile,
Main / Main10 respectively, nclx (12,13,1), on macOS 27.0.1 arm64 / Xcode 27.1.
They are immutable test inputs: no codec runs while the goldens are tested.

`display-p3.icc` is a generated Little CMS Display P3 profile with the sRGB
transfer function, using the project's existing display_p3_profile helper.
Its creation timestamp is frozen by storing these bytes; tests do not regenerate
profiles or consult the clock.

The five `.heic` files are deterministic container goldens. Their NAL payloads
are deliberately fake IDR bytes: **they are not decodable photographs**. Tests
verify container structure, bit-for-bit writer output and libheif item/reference
parsing, not picture decoding. Parameter sets are real so libheif can interpret
512x512 dimensions and 8/10-bit configuration.

- `single8`: one hvc1 item.
- `single10-crop`: one 10-bit PQ hvc1, clli and a top-left 127x95 clean aperture.
- `grid10-hlg`: 700x513 HLG grid, four hidden 512 tiles, shared hvcC, clli.
- `adaptive8-grid`: 8-bit 700x513 P3 base, 10-bit 600x513 gain, four tiles each,
  authored three-channel metadata with distinct offsets/gamma, Exif/XMP,
  auxiliary references and alternative group.
- `adaptive10-crop`: 10-bit base and gain with clean apertures, scalar metadata.

`heif_writer_fixture.hpp` defines all inputs. To deliberately refresh outputs
when reviewing an intended serialization change, build `heif_writer_test` then
run it with `--write-goldens`. Normal ctest never writes fixtures. Review changes
to the bytes, metadata and `SHA256SUMS` together; do not refresh goldens to hide
an unexpected test failure.

The current writer is a write-only API over borrowed EncodedSequence bytes.
libheif is an independent test oracle only, not a production dependency of
container. Opening fake-payload goldens says nothing about real codec quality,
Apple HDR interpretation, or macOS 26 runtime compatibility; those are V3/V5
checks.
