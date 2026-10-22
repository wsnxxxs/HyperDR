# HyperDR

HyperDR edits and exports HDR photographs on iPhone, iPad and Apple Silicon Mac
(iOS/iPadOS 26 and macOS 26). The native SwiftUI editor shares one GPU processing
graph between preview and export. ImageIO and CIRAWFilter decode, HyperDRRecipe
stores edits, HyperDRRender processes linear Display P3 and Core ML supplies AI
gain. The app picks photos from Files or the system photo library.

Exports include Adaptive HDR HEIC, ISO 21496-1 gain-map JPEG, PQ/HLG HEIC and
AVIF, SDR JPEG/TIFF, and ordinary SDR HEIC through ImageIO. Frame composition
is in Render; the native package writers enforce zero gain on SDR mats and
verify output before publishing it. VideoToolbox handles HEVC and our own HEIF
container reader/writer handles HEIC. No LGPL/GPL library ships in the app.

The C++ library is a writer/reader library, reached through C ABI 5 in
`modules/capi/include/hyperdr/hyperdr.h`. `hyperdr_package` accepts finished
float32 planes; `hyperdr_package_rows` synchronously pulls replayable rows.
There is no command-line executable, settings/report schema, panel-v1 adapter,
C++ processing graph or ncnn runtime. Swift calls the C ABI without C++ interop.

## Build and test

Use Xcode with the iOS and Metal toolchains installed, CMake, Ninja, vcpkg and
Python 3.12. Dependency versions are pinned by `vcpkg.json`; use a separate
vcpkg install root per build directory/triplet.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export TMPDIR="$(mktemp -d /tmp/hyperdr-build.XXXXXX)"
python3.12 scripts/fetch_test_fixtures.py
cmake --preset macos-arm64-codecs -B build -DPython3_EXECUTABLE="$(command -v python3.12)"
python3.12 scripts/test.py native --build-dir build
python3.12 scripts/test.py apple
python3.12 scripts/test.py ios
```

`bash scripts/build_xcframework.sh --platforms all` builds all three arm64
slices. Its archive license gate runs for every slice. Apple tests cover Swift
packages, the Mac app and localization; iOS tests build unsigned device and
simulator targets. See [iOS installation notes](apps/apple/README-iOS.md).

Local quality gates, including package-driven E5 frame checks, are documented
in [tests/quality](tests/quality/README.md). They do not require user photos or a
CI runner. Parser fuzz targets remain opt-in under `tests/fuzz`.

Windows development stopped at [6949167](https://github.com/wsnxxxs/HyperDR/tree/6949167).
The former Python/Web panel and Tauri shell were removed. Offline model training
and Core ML conversion tools remain in `HyperDR_Model/`; they are not native
engine dependencies. See [third-party notices](THIRD_PARTY_NOTICES.md).
