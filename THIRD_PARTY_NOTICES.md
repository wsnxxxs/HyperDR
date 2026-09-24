# Third-party notices

A normal codec-enabled `HyperDR` build
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
| libtiff | TIFF input and output | libtiff license (BSD-style) |
| zlib | TIFF Deflate compression and Adobe XMP look decoding | zlib license |
| Google libultrahdr 1.4.0 | Ultra HDR JPEG/R reference codec | Apache-2.0 or MIT |
| ncnn | Embedded native gain-map inference runtime | BSD-3-Clause |

Phone HTTPS certificate generation uses [cryptography](https://github.com/pyca/cryptography)
under Apache-2.0 or BSD-3-Clause. The desktop sidecar bundles this dependency;
source-panel users install it from `apps/panel/requirements.txt`. Each computer
generates its own CA; neither certificates nor private keys are distributed.
Existing [mkcert](https://github.com/FiloSottile/mkcert) (BSD-3-Clause) roots may
be reused when they match a previously configured certificate. No new mkcert
installation is required.

The exact dependency versions and feature choices are defined in
[`vcpkg.json`](vcpkg.json) and [`CMakeLists.txt`](CMakeLists.txt). Consult the
license files distributed with each dependency; this notice is an aid, not a
substitute for those license texts.

The ONNX export and ncnn conversion tools listed in
[`HyperDR_Model/requirements.txt`](HyperDR_Model/requirements.txt) are
build-time tooling only. They are not required by, or installed with, the
native release executable; its ncnn model bytes are embedded as Windows
resources.

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

## Phone connection QR code

The desktop connection dialog bundles [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator)
by Kazuhiko Arase under the MIT license. Its ES module and full license are in
`apps/panel/web/js/vendor/qrcode.mjs` and `qrcode-LICENSE.txt`. QR codes are
generated locally; connection tokens are never sent to a QR service.

## Adobe DNG SDK rendering reference

This product includes DNG technology under license by Adobe Systems Incorporated.
The ACR3 default curve in `modules/look/src/dcp_acr3_curve.inc` is from Adobe's
DNG SDK `dng_render.cpp`, revision `de700ad461e35af50b28b861943a0b0753b10929`.
Copyright 2006-2023 Adobe Systems Incorporated. All Rights Reserved.
The accompanying [DNG SDK License Agreement](licenses/Adobe-DNG-SDK-LICENSE.txt)
is retained in full. Rendering mathematics follow the same SDK's sample pipeline.
No Adobe camera profile files are distributed with HyperDR.

The static XMP LookTable reader uses the serialization format documented by
`dng_big_table.cpp` in Adobe DNG SDK 1.7.1. Its base85/zlib reader is implemented
in HyperDR; Adobe's installed XMP profiles and embedded tables are read only
when selected locally and are not distributed with the application.
