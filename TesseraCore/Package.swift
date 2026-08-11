// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesseraCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DBMCPServer", targets: ["DBMCPServer"]),
        // Domain models + protocols, with no networking/NIO dependency.
        .library(name: "DBKit", targets: ["DBKit"]),
        // Organizer and connection-profile persistence (JSON), depends only on DBKit.
        .library(name: "DBPersistence", targets: ["DBPersistence"]),
        // Keychain-backed secret storage.
        .library(name: "DBSecurity", targets: ["DBSecurity"]),
        // Database drivers implementing DBKit's DatabaseDriver.
        .library(name: "DBDriverPostgres", targets: ["DBDriverPostgres"]),
        .library(name: "DBDriverMySQL", targets: ["DBDriverMySQL"]),
        // File-based SQLite on the system libsqlite3 — no external dependency.
        .library(name: "DBDriverSQLite", targets: ["DBDriverSQLite"]),
        // Redis over a hand-rolled RESP2 client on NIO (no external dependency).
        .library(name: "DBDriverRedis", targets: ["DBDriverRedis"]),
        // SSH local port forwarding.
        .library(name: "DBTunnel", targets: ["DBTunnel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.2"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .target(name: "DBKit"),
        .target(name: "DBPersistence", dependencies: ["DBKit"]),
        .target(name: "DBSecurity", dependencies: ["DBKit"]),
        .target(
            name: "DBDriverPostgres",
            dependencies: [
                "DBKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .target(
            name: "DBDriverMySQL",
            dependencies: [
                "DBKit",
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ]
        ),
        .target(
            name: "DBDriverSQLite",
            dependencies: ["DBKit"]
        ),
        .target(
            name: "DBDriverRedis",
            dependencies: [
                "DBKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ],
            // NIO channel handlers don't fit Swift 6 strict concurrency cleanly.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DBTunnel",
            dependencies: [
                "DBKit",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            // NIO channel handlers don't fit Swift 6 strict concurrency cleanly.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DBMCPServer",
            dependencies: [
                "DBKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["DBKit", "DBPersistence", "DBSecurity"]
        ),
        .testTarget(
            name: "DBDriverRedisTests",
            dependencies: ["DBDriverRedis"]
        ),
        .testTarget(
            name: "DBMCPServerTests",
            dependencies: ["DBMCPServer"]
        ),
        .testTarget(
            name: "DBTunnelTests",
            dependencies: ["DBTunnel", "DBKit", "DBDriverPostgres"]
        ),
        .testTarget(
            name: "DBDriverPostgresTests",
            dependencies: ["DBDriverPostgres", "DBKit"]
        ),
        .testTarget(
            name: "DBDriverMySQLTests",
            dependencies: ["DBDriverMySQL", "DBKit"]
        ),
        .testTarget(
            name: "DBDriverSQLiteTests",
            dependencies: ["DBDriverSQLite", "DBKit"]
        ),
    ]
)
