# HyperDR macOS

Requires Apple Silicon, macOS 26 and Xcode 27.1. Only the macOS arm64 slice is enabled.
Run from the repository root:

```sh
scripts/build_xcframework.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path apps/apple/Packages/HyperDREngine
cd apps/apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDR -destination 'platform=macOS' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDR -destination 'platform=macOS' test
```

If Metal compilation reports a missing toolchain, install Apple's component once:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

The build script uses `build-apple/` for CMake and writes the merged static xcframework
to `build/xcframework/`. It also creates the local artifact symlink consumed by Swift
Package Manager. These products are ignored. The engine is one static library, so the
App embeds no dylibs. Gain-map JPEGs use the native parser, libjpeg-turbo and ImageIO.

`HyperDREngine` wraps the original six C ABI functions. It imports a Clang module,
with no Swift C++ interoperability. Its schema test compares the raw engine output
with the CLI built in `build-apple/`. The Metal tests additionally require Node on
`PATH` (Homebrew's default locations are included) to run the existing JS `sampleHdr`.

The iOS and iPadOS shell is the `HyperDRiOS` target and scheme in the same project
(`HyperDRiOS/`, plus `Shared/`, which both apps compile); it links only `HyperDRDesign`
for now. Installing it with a free Apple ID: `README-iOS.md`.

The app source and preview tests use Xcode synchronized folders. `HyperDR/Views/`
belongs to the static window layout; the EDR spike lives in `HyperDR/macOS/Preview/`.
The current entry view displays engine diagnostics and the 0–8× synthetic EDR ramp.
See `docs/spikes/S11-edr-preview.md` in the local documentation for measured headroom,
shader comparisons and screenshot evidence.
