// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRRender",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "HyperDRRender", targets: ["HyperDRRender"])],
    dependencies: [.package(path: "../HyperDRRecipe")],
    targets: [
        .target(name: "HyperDRRender", dependencies: ["HyperDRRecipe"],
                resources: [.copy("Shaders")]),
        .testTarget(name: "HyperDRRenderTests", dependencies: ["HyperDRRender"])
    ]
)
