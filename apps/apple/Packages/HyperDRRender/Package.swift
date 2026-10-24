// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRRender",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [.library(name: "HyperDRRender", targets: ["HyperDRRender"])],
    dependencies: [.package(path: "../HyperDRRecipe")],
    targets: [
        .target(name: "HyperDRRender", dependencies: ["HyperDRRecipe"],
                resources: [.copy("Shaders"),
                            // The AI model is not in the repository: Models/
                            // holds only its README unless a private copy of
                            // research-cnn-v1.mlpackage was put there, and a
                            // build without it offers only the analytic
                            // expansion. The mlpackage is copied verbatim:
                            // SwiftPM's Core ML build rule declares only
                            // model.mlmodel as an input, so a multi-file package
                            // fails inside the build sandbox; the model is
                            // compiled once per process instead.
                            .copy("Resources/Models"),
                            // Compiled into the bundle's default library by an Xcode
                            // build; copied as source otherwise, so the runtime can
                            // compile it itself.
                            .copy("Resources/ModelGainAnalysis.metal"),
                            // spektrafilm stocks (CC BY-SA 4.0), converted by
                            // scripts/convert_spektrafilm_stocks.py.
                            .copy("Resources/Film")]),
        .testTarget(name: "HyperDRRenderTests", dependencies: ["HyperDRRender"],
                    resources: [.copy("Fixtures")])
    ]
)
