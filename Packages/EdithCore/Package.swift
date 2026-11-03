// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EdithCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EdithCore", targets: ["EdithCore"]),
    ],
    targets: [
        // Built by scripts/build-libssh2.sh: libssh2 on a static OpenSSL.
        .binaryTarget(name: "CLibssh2", path: "Vendor/CLibssh2.xcframework"),
        .target(
            name: "EdithCore",
            dependencies: ["CLibssh2"]
        ),
        .testTarget(
            name: "EdithCoreTests",
            dependencies: ["EdithCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
