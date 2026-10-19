// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MClean",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LookupService", targets: ["LookupService"]),
        .library(name: "JunkCleanup", targets: ["JunkCleanup"]),
        .executable(name: "MClean", targets: ["MClean"]),
    ],
    targets: [
        .target(name: "LookupService"),
        .target(name: "JunkCleanup"),
        .executableTarget(name: "MClean", dependencies: ["LookupService", "JunkCleanup"]),
        .executableTarget(name: "junkscan", dependencies: ["JunkCleanup"]),
        .testTarget(name: "LookupServiceTests", dependencies: ["LookupService"]),
        .testTarget(name: "JunkCleanupTests", dependencies: ["JunkCleanup"]),
    ]
)
