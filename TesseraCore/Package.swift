// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesseraCore",
    platforms: [.macOS(.v15)],
    products: [
        // Domain models + protocols, with no networking/NIO dependency.
        .library(name: "DBKit", targets: ["DBKit"]),
        // Organizer and connection-profile persistence (JSON), depends only on DBKit.
        .library(name: "DBPersistence", targets: ["DBPersistence"]),
        // PostgreSQL driver implementing DBKit's DatabaseDriver.
        .library(name: "DBDriverPostgres", targets: ["DBDriverPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
    ],
    targets: [
        .target(name: "DBKit"),
        .target(name: "DBPersistence", dependencies: ["DBKit"]),
        .target(
            name: "DBDriverPostgres",
            dependencies: [
                "DBKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["DBKit", "DBPersistence"]
        ),
        .testTarget(
            name: "DBDriverPostgresTests",
            dependencies: ["DBDriverPostgres", "DBKit"]
        ),
    ]
)
