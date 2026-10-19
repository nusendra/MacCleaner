import AppUninstaller
import Foundation
import JunkCleanup
import SpaceLens

// Dry run: scans and prints what System Junk would offer. Never deletes anything.

func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

// `junkscan --languages <App.app>` prints the lproj folders that would be removed from one bundle.
if let flag = CommandLine.arguments.firstIndex(of: "--languages"), CommandLine.arguments.count > flag + 1 {
    let app = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    for (_, folders) in JunkCleanupInspection.removableLocalizations(in: app) {
        folders.forEach { print($0.path) }
    }
    exit(0)
}

// `junkscan --app <name>` lists every file the uninstaller would attribute to that app.
// `junkscan --leftovers` lists bundle ids with files but no installed app.
let apps = CommandLine.arguments.contains("--app") || CommandLine.arguments.contains("--leftovers") ? ApplicationDiscovery.installedApplications() : []
if let flag = CommandLine.arguments.firstIndex(of: "--app"), CommandLine.arguments.count > flag + 1 {
    let query = CommandLine.arguments[flag + 1].lowercased()
    let scanner = AppResourcesScanner()
    for app in apps where app.displayName.lowercased().contains(query) {
        print("\(app.displayName) [\(app.bundleIdentifier ?? "-")] store=\(app.store.rawValue) system=\(app.isSystem) unused=\(app.isUnused())")
        for resource in scanner.resources(for: app).sorted(by: { ($0.group.rawValue, $0.path) < ($1.group.rawValue, $1.path) }) {
            print("   \(resource.isRemovable ? "[x]" : "[ ]") \(resource.group.rawValue): \(resource.path) \(size(resource.size))")
        }
    }
    exit(0)
}
if CommandLine.arguments.contains("--leftovers") {
    let installed = ApplicationDiscovery.installedBundleIdentifiers(apps: apps, home: JunkPaths.current.home)
    let leftovers = LeftoversScanner().candidates(installedIDs: installed)
    let scanner = AppResourcesScanner()
    for candidate in leftovers {
        let resources = scanner.resources(for: InstalledApplication(leftoverBundleID: candidate.bundleID, name: candidate.name))
        print("\(candidate.bundleID) (\(candidate.name)) \(size(resources.reduce(0) { $0 + $1.size })) from \(candidate.sourcePath)")
        resources.forEach { print("     \($0.group.rawValue): \($0.path)") }
    }
    exit(0)
}

// `junkscan --lens <path>` builds the Space Lens tree and prints the biggest items (read-only).
if let flag = CommandLine.arguments.firstIndex(of: "--lens"), CommandLine.arguments.count > flag + 1 {
    let start = Date()
    let tree = try await SpaceLensScanner().scan(URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
    func count(_ node: SpaceLensNode) -> Int { 1 + node.children.reduce(0) { $0 + count($1) } }
    print(String(format: "%@: %@, %d nodes, %.1fs", tree.path, size(tree.size), count(tree), Date().timeIntervalSince(start)))
    for child in tree.children.prefix(12) {
        print("   \(size(child.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.name) \(child.kind == .needsAccess ? "(needs Full Disk Access)" : "")")
    }
    exit(0)
}

let verbose = CommandLine.arguments.contains("-v")
let start = Date()
let result = await JunkScanner().scan { progress in
    FileHandle.standardError.write(Data("\r[\(progress.finishedTasks)/\(progress.totalTasks)] \(progress.currentTitle)\u{1B}[K".utf8))
}
FileHandle.standardError.write(Data("\n".utf8))

for group in result.groups {
    let selected = group.items.filter(\.isAutoSelected).reduce(Int64(0)) { $0 + $1.size }
    print("\(group.id.title): \(size(group.size)) (\(size(selected)) preselected, \(group.items.count) items)")
    for subgroup in group.subgroups.sorted(by: { $0.size > $1.size }).prefix(verbose ? .max : 5) {
        print("   \(subgroup.title): \(size(subgroup.size)), \(subgroup.items.count) items")
        if verbose {
            for item in subgroup.items {
                print("      [\(item.isAutoSelected ? "x" : " ")] \(item.name) \(size(item.size)) \(item.url?.path ?? "")")
            }
        }
    }
}
for (task, error) in result.failures.sorted(by: { $0.key < $1.key }) {
    print("FAILED \(task): \(error)")
}
print(String(format: "Total %@ in %.1fs", size(result.totalSize), Date().timeIntervalSince(start)))
