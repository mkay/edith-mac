// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EdithEditor",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "EdithEditor", targets: ["EdithEditor"]),
    ],
    targets: [
        .target(
            name: "EdithEditor",
            // Monaco's vs/ tree, emmet, terser and csso come from
            // scripts/fetch-monaco.sh; bridge.js and editor.html are ours.
            resources: [.copy("Resources/Monaco")]
        ),
        .testTarget(name: "EdithEditorTests", dependencies: ["EdithEditor"]),
    ]
)
