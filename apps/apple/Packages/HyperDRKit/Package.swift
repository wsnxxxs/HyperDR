// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "HyperDRKit", targets: ["HyperDRKit"])],
    dependencies: [.package(path: "../HyperDREngine"), .package(path: "../HyperDRRecipe"), .package(path: "../HyperDRRender")],
    targets: [
        .target(name: "HyperDRKit", dependencies: [
            .product(name: "HyperDREngine", package: "HyperDREngine"),
            .product(name: "HyperDRRecipe", package: "HyperDRRecipe"),
            .product(name: "HyperDRRender", package: "HyperDRRender")
        ]),
        .testTarget(name: "HyperDRKitTests", dependencies: ["HyperDRKit"],
                    resources: [.process("Fixtures")]),
    ]
)
