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
        // Keychain-backed secret storage.
        .library(name: "DBSecurity", targets: ["DBSecurity"]),
        // Database drivers implementing DBKit's DatabaseDriver.
        .library(name: "DBDriverPostgres", targets: ["DBDriverPostgres"]),
        .library(name: "DBDriverMySQL", targets: ["DBDriverMySQL"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.2"),
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
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["DBKit", "DBPersistence", "DBSecurity"]
        ),
        .testTarget(
            name: "DBDriverPostgresTests",
            dependencies: ["DBDriverPostgres", "DBKit"]
        ),
        .testTarget(
            name: "DBDriverMySQLTests",
            dependencies: ["DBDriverMySQL", "DBKit"]
        ),
    ]
)
