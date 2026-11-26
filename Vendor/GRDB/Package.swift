// swift-tools-version:6.1
// Vendored GRDB 7.12.0 (https://github.com/groue/GRDB.swift, MIT licence), built against SQLCipher.
// Changes from upstream: the "GRDB+SQLCipher" steps of the upstream Package.swift are applied,
// and the test target and documentation plugin are removed.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .define("SQLITE_ENABLE_FTS5"),
    .define("SQLITE_ENABLE_SNAPSHOT"),
    .define("SQLITE_HAS_CODEC"),
    .define("SQLCipher"),
]
let cSettings: [CSetting] = [
    .define("SQLITE_HAS_CODEC"),
]

let package = Package(
    name: "GRDB",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(name: "GRDB", targets: ["GRDB"]),
    ],
    dependencies: [
        // Official Zetetic package (signed binary XCFramework).
        .package(url: "https://github.com/sqlcipher/SQLCipher.swift.git", exact: "4.20.0"),
    ],
    targets: [
        .target(
            name: "GRDBSQLCipher",
            dependencies: [.product(name: "SQLCipher", package: "SQLCipher.swift")]
        ),
        .target(
            name: "GRDB",
            dependencies: [
                .product(name: "SQLCipher", package: "SQLCipher.swift"),
                .target(name: "GRDBSQLCipher"),
            ],
            path: "GRDB",
            resources: [.copy("PrivacyInfo.xcprivacy")],
            cSettings: cSettings,
            swiftSettings: swiftSettings + [
                .enableUpcomingFeature("MemberImportVisibility"),
            ]),
    ],
    swiftLanguageModes: [.v6]
)
