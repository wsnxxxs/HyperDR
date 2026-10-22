# HyperDR macOS

Requires Apple Silicon, macOS 27 and Xcode 27.1. The Mac target uses the macOS arm64 engine slice.
Run from the repository root:

```sh
scripts/build_xcframework.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path apps/apple/Packages/HyperDREngine
cd apps/apple
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDR -destination 'platform=macOS,arch=arm64' build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme HyperDR -destination 'platform=macOS,arch=arm64' test
```

If Metal compilation reports a missing toolchain, install Apple's component once:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -downloadComponent MetalToolchain
```

The build script uses `build-apple/` for CMake and writes the merged static xcframework
to `build/xcframework/`. It also creates the local artifact symlink consumed by Swift
Package Manager. These products are ignored. The engine is one static library, so the
App embeds no dylibs. Gain-map JPEGs use the native parser, libjpeg-turbo and ImageIO.

`HyperDREngine` wraps C ABI 5: writer capabilities, probing, frame layout and
whole-plane/replayable-row packaging. It imports a Clang module without Swift
C++ interoperability. There is no CLI or schema adapter. The Metal tests additionally require Node on
`PATH` (Homebrew's default locations are included) to run the existing JS `sampleHdr`.

The iOS and iPadOS app is the `HyperDRiOS` target and scheme in the same project
(`HyperDRiOS/`, plus `Shared/`, which both apps compile); it links the shared Recipe, Render, Design and Kit packages. Installing it with a free Apple ID: `README-iOS.md`.

The app source and preview tests use Xcode synchronized folders. `HyperDR/Views/`
binds to the editor models, while the shared RecipeEditor and HyperDRRender own
editing and rendering. The Mac EDR canvas supports original/split comparison,
actual-pixel detail and pan. The editor includes film and LUT looks, presentation
frames, and JPEG/HEIC/AVIF/TIFF exports. See the root README for pipeline details.
