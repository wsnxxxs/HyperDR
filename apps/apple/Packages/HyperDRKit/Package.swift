// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HyperDRKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "HyperDRKit", targets: ["HyperDRKit"]),
               .executable(name: "HyperDRKitParity", targets: ["HyperDRKitParity"])],
    dependencies: [.package(path: "../HyperDREngine")],
    targets: [
        .target(name: "HyperDRKit", dependencies: [
            .product(name: "HyperDREngine", package: "HyperDREngine")
        ]),
        .executableTarget(name: "HyperDRKitParity", dependencies: ["HyperDRKit"]),
        .testTarget(name: "HyperDRKitTests", dependencies: ["HyperDRKit"],
                    resources: [.process("Fixtures")]),
    ]
)
