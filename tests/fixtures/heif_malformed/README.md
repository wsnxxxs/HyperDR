# Deterministic HEIF robustness specimens

CC0 synthetic data. Rebuild all 72 files and `manifest.json` with Python 3.10+:

```sh
python3 tests/fixtures/heif_malformed/generate.py
```

Every specimen is below 64 KiB. The manifest specifies the complete reader plus
image/gain/alpha resolver's error code and optional machine-readable feature.
`ok` entries are positive controls, including v2/v3 item IDs, wide ipma indices,
idat, grid, iden→grid, both alpha URNs/premultiplication, legacy Apple gain maps,
ordered transforms, an unused item's unknown essential property, optional tmap
properties, and largesize meta/iref/iprp/ipma/altr boxes. A consumed tmap item
with an unknown essential property must fail with `essential_property`.

`heif_malformed_test` also sends every file through structural inspection, runs
on a 512 KiB stack, and enforces one second per specimen. Resource-limit boundary
acceptance and rejection (including ICC/metadata/sample sizes too large for this
small-file corpus) live in `heif_reader_limits_test`.

`inspect-short-iref` is a minimized deterministic regression for fuzz artifact
`a0214c04819cfdae0cfa04f52737903b39bed2d5`: without a meta box, inspect's fragment
walker used to skip four full-box bytes beyond an empty iref and form a reversed
subspan. Both the fragment walker and the shared cursor now reject that range.

A HEIF parser can reject framing/header defects without decoding. Valid-looking
corrupt entropy-coded slices cannot be classified here; their VideoToolbox
callback behavior is tested separately in P3b-2. Grid rows/columns and ipma
association counts have byte-wide representable maxima; impossible encodings
are covered at the shared limit-check helper or by duplicate/truncated fields.
