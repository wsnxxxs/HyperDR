// swift-tools-version: 6.2
import Foundation
import PackageDescription

let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../build/xcframework/Runtime").standardized.path

let package = Package(
    name: "HyperDREngine",
    platforms: [.macOS(.v26)],
    products: [.library(name: "HyperDREngine", targets: ["HyperDREngine"])],
    targets: [
        .binaryTarget(name: "HyperDREngineCore", path: "Artifacts/HyperDREngineCore.xcframework"),
        .target(name: "HyperDREngine", dependencies: ["HyperDREngineCore"], linkerSettings: [
            .linkedLibrary("c++"), .linkedLibrary("heif"),
            .linkedFramework("CoreFoundation"),
            .linkedFramework("Accelerate"),
            .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
            .linkedFramework("CoreVideo"),
            .unsafeFlags(["-L", runtime, "-Xlinker", "-rpath", "-Xlinker", runtime])
        ]),
        .testTarget(name: "HyperDREngineTests", dependencies: ["HyperDREngine"])
    ]
)
