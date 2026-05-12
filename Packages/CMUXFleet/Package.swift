// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CMUXFleet",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CMUXFleet",
            targets: ["CMUXFleet"]
        ),
    ],
    targets: [
        .target(
            name: "CMUXFleet"
        ),
        .testTarget(
            name: "CMUXFleetTests",
            dependencies: ["CMUXFleet"]
        ),
    ]
)
