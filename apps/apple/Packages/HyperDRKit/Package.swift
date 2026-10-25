// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRKit",
    defaultLocalization: "en",
    platforms: [.macOS("15.0"), .iOS("27.0")],
    products: [.library(name: "HyperDRKit", targets: ["HyperDRKit"])],
    dependencies: [.package(path: "../HyperDREngine"), .package(path: "../HyperDRRecipe"), .package(path: "../HyperDRRender")],
    targets: [
        .target(name: "HyperDRKit", dependencies: [
            .product(name: "HyperDREngine", package: "HyperDREngine"),
            .product(name: "HyperDRRecipe", package: "HyperDRRecipe"),
            .product(name: "HyperDRRender", package: "HyperDRRender")
        ], resources: [.process("Resources")]),
        .testTarget(name: "HyperDRKitTests", dependencies: ["HyperDRKit"]),
    ]
)
