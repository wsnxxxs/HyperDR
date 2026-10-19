# Third-party notices

A normal codec-enabled `HyperDR` build
resolves the dependencies below through vcpkg or CMake `FetchContent`.

| Component | Purpose | Upstream license information |
| --- | --- | --- |
| Little CMS 2 | ICC profile construction | MIT |
| libavif | AVIF container and image encoding | BSD-2-Clause |
| Alliance for Open Media libaom | AV1 codec selected by libavif's `aom` feature | BSD-2-Clause-style license and patent grant; see upstream `LICENSE` and `PATENTS` |
| libjpeg-turbo | JPEG input, preview output, and Ultra HDR support | IJG, modified BSD, and zlib licenses |
| libpng | PNG input decoding | libpng-2.0 |
| libtiff | TIFF input and output | libtiff license (BSD-style) |
| zlib | TIFF Deflate compression | zlib license |
| liblzma (XZ Utils) | TIFF LZMA compression, through libtiff | 0BSD (the liblzma library) |
| libyuv | Colour conversion and scaling inside libavif | BSD-3-Clause |
| ncnn | Embedded native gain-map inference runtime | BSD-3-Clause |

## Platform codec configurations

The native application targets macOS 26 and later on Apple Silicon. HEVC
encoding and decoding use Apple's VideoToolbox framework, and HEIF reading and
writing use HyperDR's own code. No LGPL or GPL library is linked or shipped;
every dependency above is statically linked.

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
