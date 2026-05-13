// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXPty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXPty",
            targets: ["CMUXPty"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXPty"
        ),
        .testTarget(
            name: "CMUXPtyTests",
            dependencies: ["CMUXPty"]
        ),
    ]
)
