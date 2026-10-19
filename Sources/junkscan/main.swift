import Foundation
import JunkCleanup

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
