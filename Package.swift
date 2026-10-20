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
        .target(name: "Maintenance", dependencies: ["JunkCleanup"]),
        // The modern LAPACK interface (the CLAPACK one is deprecated) for the photo noise estimate.
        .target(name: "Duplicates", dependencies: ["JunkCleanup"], swiftSettings: [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])]),
        .executableTarget(name: "MacCleaner", dependencies: ["JunkCleanup", "AppUninstaller", "SpaceLens", "Maintenance", "Duplicates"]),
        .executableTarget(name: "junkscan", dependencies: ["JunkCleanup", "AppUninstaller", "SpaceLens", "Duplicates"]),
        .testTarget(name: "LookupServiceTests", dependencies: ["LookupService"]),
        .testTarget(name: "JunkCleanupTests", dependencies: ["JunkCleanup"]),
        .testTarget(name: "AppUninstallerTests", dependencies: ["AppUninstaller", "JunkCleanup"]),
        .testTarget(name: "SpaceLensTests", dependencies: ["SpaceLens", "JunkCleanup"]),
        .testTarget(name: "MaintenanceTests", dependencies: ["Maintenance"]),
        .testTarget(name: "DuplicatesTests", dependencies: ["Duplicates"]),
    ]
)
