// swift-tools-version: 6.0

// Phase 0 spike: the same SFTP checks against libssh2 and Citadel, to pick
// the library EdithCore's SFTPClient is built on. Not part of the app.
// libssh2 comes from Homebrew here; the app will vendor its own build.

import PackageDescription

let package = Package(
    name: "SFTPSpike",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
    ],
    targets: [
        .systemLibrary(name: "CLibssh2", path: "Sources/CLibssh2"),
        .target(name: "SpikeKit"),
        .executableTarget(
            name: "sftp-spike-libssh2",
            dependencies: ["CLibssh2", "SpikeKit"],
            linkerSettings: [.unsafeFlags(["-L/opt/homebrew/lib"])]
        ),
        .executableTarget(
            name: "sftp-spike-citadel",
            dependencies: ["SpikeKit", .product(name: "Citadel", package: "Citadel")]
        ),
    ]
)
