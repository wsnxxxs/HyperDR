// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDREngine",
    platforms: [.macOS("15.0"), .iOS("27.0")],
    products: [.library(name: "HyperDREngine", targets: ["HyperDREngine"])],
    targets: [
        .binaryTarget(name: "HyperDREngineCore", path: "Artifacts/HyperDREngineCore.xcframework"),
        .target(name: "HyperDREngine", dependencies: ["HyperDREngineCore"], linkerSettings: [
            .linkedLibrary("c++"),
            .linkedFramework("CoreFoundation"), .linkedFramework("Metal"),
            .linkedFramework("Accelerate"),
            .linkedFramework("VideoToolbox"), .linkedFramework("CoreMedia"),
            .linkedFramework("CoreVideo")
        ]),
        .testTarget(name: "HyperDREngineTests", dependencies: ["HyperDREngine"])
    ]
)
