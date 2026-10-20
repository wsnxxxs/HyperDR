// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRRecipe",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "HyperDRRecipe", targets: ["HyperDRRecipe"])],
    targets: [.target(name: "HyperDRRecipe"),
              .testTarget(name: "HyperDRRecipeTests", dependencies: ["HyperDRRecipe"])]
)
