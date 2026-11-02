// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenCloudSync",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenCloudCore", targets: ["OpenCloudCore"]),
        .library(name: "OpenCloudFileProvider", targets: ["OpenCloudFileProvider"]),
        .executable(name: "OpenCloudSync", targets: ["OpenCloudSyncApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "OpenCloudCore", dependencies: ["CSQLite"]),
        .target(name: "OpenCloudFileProvider", dependencies: ["OpenCloudCore"]),
        .executableTarget(name: "OpenCloudSyncApp", dependencies: ["OpenCloudCore"]),
        .testTarget(name: "OpenCloudCoreTests", dependencies: ["OpenCloudCore", "OpenCloudFileProvider"]),
        .testTarget(name: "LiveIntegrationTests", dependencies: ["OpenCloudCore"], resources: [.copy("Fixtures")])
    ]
)
