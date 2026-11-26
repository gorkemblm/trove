// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trove",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/GRDB"),
    ],
    targets: [
        .executableTarget(
            name: "Trove",
            dependencies: [
                .product(name: "GRDB", package: "GRDB"),
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
