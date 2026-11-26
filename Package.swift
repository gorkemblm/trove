// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clipboard",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Vendor/GRDB"),
    ],
    targets: [
        .executableTarget(
            name: "Clipboard",
            dependencies: [
                .product(name: "GRDB", package: "GRDB"),
            ],
            path: "Sources/Clipboard"
        ),
        .testTarget(
            name: "ClipboardTests",
            dependencies: ["Clipboard"],
            path: "Tests/ClipboardTests"
        ),
    ]
)
