// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EdithCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EdithCore", targets: ["EdithCore"]),
    ],
    targets: [
        // Built by scripts/build-libssh2.sh: libssh2 on a static OpenSSL.
        .binaryTarget(name: "CLibssh2", path: "Vendor/CLibssh2.xcframework"),
        .target(
            name: "EdithCore",
            dependencies: ["CLibssh2"],
            // Error messages the app shows, in English and German.
            resources: [.process("Resources/Localizable.xcstrings")]
        ),
        .testTarget(
            name: "EdithCoreTests",
            dependencies: ["EdithCore"],
            exclude: ["Support/ftpserver.py"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
