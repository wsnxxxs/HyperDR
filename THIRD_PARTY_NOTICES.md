# Third-party notices

HyperDR's own source code is available under the GNU Affero General Public
License v3.0 or a commercial license (`LICENSE` and `LICENSING.md` in its
repository). The components below keep their own licenses.

A normal codec-enabled `HyperDR` build
resolves the dependencies below through vcpkg or CMake `FetchContent`.

| Component | Purpose | Upstream license information |
| --- | --- | --- |
| LibRaw | Camera RAW sensor unpacking and capture metadata for DNG compatibility | CDDL-1.0 (selected from the upstream dual license); bundled dcraw, DCB/FBDD, X3F and Adobe notices in `licenses/LibRaw-COPYRIGHT.txt` |
| JasPer | JPEG-2000 support inside LibRaw | JasPer License 2.0 (BSD-style) |
| Little CMS 2 | ICC profile construction | MIT |
| libavif | AVIF container and image encoding | BSD-2-Clause |
| Alliance for Open Media libaom | AV1 codec selected by libavif's `aom` feature | BSD-2-Clause-style license and patent grant; see upstream `LICENSE` and `PATENTS` |
| libjpeg-turbo | JPEG input, preview output, and Ultra HDR support | IJG, modified BSD, and zlib licenses |
| libpng | PNG input decoding | libpng-2.0 |
| libtiff | TIFF input and output | libtiff license (BSD-style) |
| zlib | TIFF Deflate compression | zlib license |
| liblzma (XZ Utils) | TIFF LZMA compression, through libtiff | 0BSD (the liblzma library) |
| libyuv | Colour conversion and scaling inside libavif | BSD-3-Clause |

## Platform codec configurations

The native applications target macOS 27 and later on Apple Silicon, and
iOS and iPadOS 27 and later. HEVC
encoding and decoding use Apple's VideoToolbox framework, and HEIF reading and
writing use HyperDR's own code. No LGPL or GPL library is linked or shipped;
every dependency above is statically linked.

LibRaw is used under **CDDL-1.0**, without the alternative LGPL license,
OpenMP or the historical GPL demosaic packs. Its full [CDDL-1.0 text](licenses/LibRaw-CDDL-1.0.txt)
and [upstream copyright and dcraw-related notices](licenses/LibRaw-COPYRIGHT.txt)
are distributed with the source. Distributors must make the corresponding
LibRaw source and any modifications available under CDDL-1.0. The pinned
snapshot is identified by `cmake/ports/libraw/portfile.cmake`; its upstream
source archive is `https://github.com/LibRaw/LibRaw/archive/2caab57e269cc7fce17c3189e4d4d7e3e5861875.tar.gz`.
No LibRaw code is copied into HyperDR's own source files.

The exact dependency versions and feature choices are defined in
[`vcpkg.json`](vcpkg.json) and [`CMakeLists.txt`](CMakeLists.txt). Consult the
license files distributed with each dependency; this notice is an aid, not a
substitute for those license texts.

Film emulation uses film stock data derived from spektrafilm by Andrea
Volpato (https://github.com/andreavolpato/spektrafilm), licensed CC BY-SA 4.0
(https://creativecommons.org/licenses/by-sa/4.0/). HyperDR converted the
Kodak Portra 400, Kodak Gold 200, Kodak Portra Endura, Fujifilm Velvia 100,
Kodak Kodachrome 64, Kodak Vision3 500T and Kodak 2383 profiles with `scripts/convert_spektrafilm_stocks.py` (spectral
upsampling baked per film, illuminants, neutral print filters, scanner levels
and fitted curves resolved, grain variance and halation parameters tabulated); the converted data in `HyperDRRender/Resources/Film` remains
CC BY-SA 4.0. No spektrafilm code is included. Stock names are trademarks of
their owners and only name the look's reference.

Model inference uses Core ML in HyperDRRender. Training and ONNX export tools
in `HyperDR_Model/` are offline tools and are not linked into the engine.
The experimental denoising implementation in `HyperDR_Model/denoise/nafnet.py`
is derived from NAFNet (Copyright (c) 2022 megvii-model), under the MIT License;
the upstream license text is included in `HyperDR_Model/denoise/NAFNet-LICENSE.txt`.
Downloaded RawNIND datasets, model checkpoints and the trained AI model weights
are not distributed.

`libavif` and its libaom codec are build dependencies for the two AVIF output
formats; they are not merely reference implementations. The ISO 21496 metadata
field ordering in `modules/container/src/iso_gain_map.cpp` follows published standard syntax and was
cross-checked against libavif; no third-party source code is copied into that
implementation.

HEVC may be subject to patent rights in some jurisdictions. Before distributing
binaries, bundling codecs, or offering a hosted conversion service, review all
applicable dependency licenses and patent obligations with qualified counsel.
