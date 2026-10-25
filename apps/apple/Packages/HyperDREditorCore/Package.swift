// swift-tools-version: 6.2
import PackageDescription

// Test harness for `apps/apple/Shared/Editor`, which both app targets compile
// as their own sources. `Sources/HyperDREditorCore` is a symbolic link to that
// directory, so the editing core's tests run with `swift test`, without
// building or launching an app. The apps do not link this package.
let package = Package(
    name: "HyperDREditorCore",
    platforms: [.macOS("15.0"), .iOS("27.0")],
    dependencies: [.package(path: "../HyperDRRecipe"), .package(path: "../HyperDRRender")],
    targets: [
        // The apps build with MainActor default isolation; so does this target.
        .target(name: "HyperDREditorCore", dependencies: [
            .product(name: "HyperDRRecipe", package: "HyperDRRecipe"),
            .product(name: "HyperDRRender", package: "HyperDRRender"),
        ], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "HyperDREditorCoreTests", dependencies: [
            "HyperDREditorCore", .product(name: "HyperDRRecipe", package: "HyperDRRecipe"),
            .product(name: "HyperDRRender", package: "HyperDRRender"),
        ]),
    ]
)
