// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LookupService", targets: ["LookupService"]),
        .library(name: "JunkCleanup", targets: ["JunkCleanup"]),
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
    ],
    targets: [
        .target(name: "LookupService"),
        .target(name: "JunkCleanup"),
        .target(name: "AppUninstaller", dependencies: ["JunkCleanup"]),
        .target(name: "SpaceLens", dependencies: ["JunkCleanup"]),
        .executableTarget(name: "MacCleaner", dependencies: ["JunkCleanup", "AppUninstaller", "SpaceLens"]),
        .executableTarget(name: "junkscan", dependencies: ["JunkCleanup", "AppUninstaller", "SpaceLens"]),
        .testTarget(name: "LookupServiceTests", dependencies: ["LookupService"]),
        .testTarget(name: "JunkCleanupTests", dependencies: ["JunkCleanup"]),
        .testTarget(name: "AppUninstallerTests", dependencies: ["AppUninstaller", "JunkCleanup"]),
        .testTarget(name: "SpaceLensTests", dependencies: ["SpaceLens", "JunkCleanup"]),
    ]
)
