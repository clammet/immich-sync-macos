// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ImmichSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImmichCore", targets: ["ImmichCore"]),
        .library(name: "ImmichFileProvider", targets: ["ImmichFileProvider"]),
        .executable(name: "ImmichSync", targets: ["ImmichSyncApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "ImmichCore", dependencies: ["CSQLite"]),
        .target(name: "ImmichFileProvider", dependencies: ["ImmichCore"]),
        .executableTarget(name: "ImmichSyncApp", dependencies: ["ImmichCore"]),
        .testTarget(name: "ImmichCoreTests", dependencies: ["ImmichCore", "ImmichFileProvider"])
    ]
)
