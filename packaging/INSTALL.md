# HyperDR on macOS

HyperDR currently targets macOS 26 on Apple Silicon. Follow the macOS build
instructions in README.md to build the CLI and the C ABI libraries. The SwiftUI
application is under development in `apps/apple/`.

This transitional desktop build supports HEIC decoding and JPEG, TIFF,
Ultra HDR JPEG/R and AVIF exports. HEVC exports require the planned VideoToolbox
encoder. Keep the codec dependencies available beside a development build.

Windows instructions and packages belong to the frozen revision
[`a43d46a`](https://github.com/wsnxxxs/HyperDR/tree/a43d46a).
