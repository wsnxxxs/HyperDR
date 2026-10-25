// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRRecipe",
    platforms: [.macOS("15.0"), .iOS("27.0")],
    products: [.library(name: "HyperDRRecipe", targets: ["HyperDRRecipe"])],
    targets: [.target(name: "HyperDRRecipe"),
              .testTarget(name: "HyperDRRecipeTests", dependencies: ["HyperDRRecipe"])]
)
