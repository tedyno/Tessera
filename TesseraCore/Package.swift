// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TesseraCore",
    platforms: [.macOS(.v15)],
    products: [
        // Doménové modely + protokoly, bez jakékoli síťové/NIO závislosti.
        .library(name: "DBKit", targets: ["DBKit"]),
        // Perzistence organizátoru a connection profilů (JSON), závisí jen na DBKit.
        .library(name: "DBPersistence", targets: ["DBPersistence"]),
    ],
    targets: [
        .target(name: "DBKit"),
        .target(name: "DBPersistence", dependencies: ["DBKit"]),
        .testTarget(
            name: "TesseraCoreTests",
            dependencies: ["DBKit", "DBPersistence"]
        ),
    ]
)
