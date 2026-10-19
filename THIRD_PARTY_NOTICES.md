# Third-party notices

A normal codec-enabled `HyperDR` build
resolves the dependencies below through vcpkg or CMake `FetchContent`.

| Component | Purpose | Upstream license information |
| --- | --- | --- |
| Little CMS 2 | ICC profile construction | MIT |
| libheif | Transitional HEIF reading and decoding | LGPL-3.0-or-later |
| libde265 | HEVC decoding selected by libheif | LGPL-3.0-or-later |
| libavif | AVIF container and image encoding | BSD-2-Clause |
| Alliance for Open Media libaom | AV1 codec selected by libavif's `aom` feature | BSD-2-Clause-style license and patent grant; see upstream `LICENSE` and `PATENTS` |
| libjpeg-turbo | JPEG input, preview output, and Ultra HDR support | IJG, modified BSD, and zlib licenses |
| libpng | PNG input decoding | libpng-2.0 |
| libtiff | TIFF input and output | libtiff license (BSD-style) |
| zlib | TIFF Deflate compression | zlib license |
| ncnn | Embedded native gain-map inference runtime | BSD-3-Clause |

## Platform codec configurations

The native application targets macOS 26 and later on Apple Silicon. HEVC
encoding uses Apple's VideoToolbox framework, and HEIF writing uses HyperDR's
own writer. libheif and libde265 remain dynamic decoder libraries under
LGPL-3.0-or-later; they are used only for HEIF reading and decoding.
Corresponding source and replacement/relinking instructions must accompany
these libraries when distributed. P3b will replace the remaining reader with
HyperDR's HEIF parser and VideoToolbox decoding and remove these dependencies.

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
native release executable; its ncnn model bytes are embedded as aligned C++
byte arrays on every platform.

`libavif` and its libaom codec are build dependencies for the two AVIF output
formats; they are not merely reference implementations. The ISO 21496 metadata
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
