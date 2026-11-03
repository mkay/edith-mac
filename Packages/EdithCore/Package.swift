// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EdithCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EdithCore", targets: ["EdithCore"]),
    ],
    targets: [
        .target(name: "EdithCore"),
        .testTarget(
            name: "EdithCoreTests",
            dependencies: ["EdithCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
