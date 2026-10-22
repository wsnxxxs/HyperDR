// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRDesign",
    defaultLocalization: "en",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "HyperDRDesign", targets: ["HyperDRDesign"]),
    ],
    dependencies: [.package(path: "../HyperDRRecipe")],
    targets: [
        .target(
            name: "HyperDRDesign",
            dependencies: [.product(name: "HyperDRRecipe", package: "HyperDRRecipe")],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "HyperDRDesignTests", dependencies: [
            "HyperDRDesign", .product(name: "HyperDRRecipe", package: "HyperDRRecipe"),
        ]),
    ]
)
