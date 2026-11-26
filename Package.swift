// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/GRDB"),
        // Updates: the signed, notarized binary framework published by the Sparkle project.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "Trove",
            dependencies: [
                .product(name: "GRDB", package: "GRDB"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Trove"
        ),
        .testTarget(
            name: "TroveTests",
            dependencies: ["Trove"],
            path: "Tests/TroveTests"
        ),
    ]
)
