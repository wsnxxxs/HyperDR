# Third-party notices

`HyperDR` does not vendor third-party source code. A normal codec-enabled build
resolves the dependencies below through vcpkg or CMake `FetchContent`.

| Component | Purpose | Upstream license information |
| --- | --- | --- |
| LibRaw | Camera RAW decoding | LGPL-2.1-or-later or CDDL-1.0 |
| Little CMS 2 | ICC profile construction | MIT |
| libheif | HEIF container and image encoding | LGPL-2.1-or-later |
| x265 | HEVC encoding selected by libheif's `hevc` feature | GPL-2.0-or-later |
| libavif | AVIF container and image encoding | BSD-2-Clause |
| Alliance for Open Media libaom | AV1 codec selected by libavif's `aom` feature | BSD-2-Clause-style license and patent grant; see upstream `LICENSE` and `PATENTS` |
| libjpeg-turbo | JPEG input, preview output, and Ultra HDR support | IJG, modified BSD, and zlib licenses |
| libpng | PNG input decoding | libpng-2.0 |
| Google libultrahdr 1.4.0 | Ultra HDR JPEG/R reference codec | Apache-2.0 or MIT |

`Setup-HTTPS.bat` offers to install [mkcert](https://github.com/FiloSottile/mkcert)
(BSD-3-Clause) through winget, and later invokes it to issue the local
certificate. mkcert is neither redistributed in this repository nor included in
any release archive; it is installed on, and remains owned by, the end user's
machine. The certificate authority it creates is generated per computer and is
never shipped.

The exact dependency versions and feature choices are defined in
[`vcpkg.json`](vcpkg.json) and [`CMakeLists.txt`](CMakeLists.txt). Consult the
license files distributed with each dependency; this notice is an aid, not a
substitute for those license texts.

`libavif` and its libaom codec are build dependencies for the two AVIF output
formats; they are not merely reference implementations. Google's libultrahdr
distribution includes Adobe HDR Gain Map technology under
the terms in its `adobe-hdr-gain-map-license` directory. The ISO 21496 metadata
field ordering in `modules/container/src/iso_gain_map.cpp` follows published standard syntax and was
cross-checked against libavif; no third-party source code is copied into that
implementation.

HEVC may be subject to patent rights in some jurisdictions. Before distributing
binaries, bundling codecs, or offering a hosted conversion service, review all
applicable dependency licenses and patent obligations with qualified counsel.
