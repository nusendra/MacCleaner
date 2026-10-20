import Darwin
import Foundation
import JunkCleanup

/// One maintenance routine. Tasks that need root run through a single administrator prompt per batch.
public struct MaintenanceTask: Identifiable, Hashable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case freeUpRAM, thinSnapshots, flushDNS, reindexSpotlight, repairPermissions, periodicScripts, speedUpMail
    }

    public var id: ID
    public var title: String
    public var summary: String
    public var symbol: String
    public var needsAdmin: Bool
    /// Selected by default when the screen opens.
    public var recommended: Bool

    public static let all: [MaintenanceTask] = [
        MaintenanceTask(id: .freeUpRAM, title: "Free Up RAM",
                        summary: "Clear inactive memory so apps that need it get room to work.",
                        symbol: "memorychip", needsAdmin: true, recommended: true),
        MaintenanceTask(id: .thinSnapshots, title: "Thin Time Machine Snapshots",
                        summary: "Remove local Time Machine snapshots macOS keeps on this disk, freeing their space now.",
                        symbol: "clock.arrow.circlepath", needsAdmin: false, recommended: false),
        MaintenanceTask(id: .flushDNS, title: "Flush DNS Cache",
                        summary: "Forget cached website addresses; fixes sites that do not load after a network change.",
                        symbol: "network", needsAdmin: true, recommended: true),
        MaintenanceTask(id: .reindexSpotlight, title: "Reindex Spotlight",
                        summary: "Rebuild the Spotlight index when search misses files. Indexing runs for a while afterwards.",
                        symbol: "magnifyingglass", needsAdmin: true, recommended: false),
        MaintenanceTask(id: .repairPermissions, title: "Repair Disk Permissions",
                        summary: "Reset the permissions of your home folder files; fixes apps that cannot save or open files.",
                        symbol: "lock.rotation", needsAdmin: true, recommended: false),
        MaintenanceTask(id: .periodicScripts, title: "Run Maintenance Scripts",
                        summary: "Run the daily, weekly and monthly system scripts that rotate logs and clean temporary files.",
                        symbol: "terminal", needsAdmin: true, recommended: false),
        MaintenanceTask(id: .speedUpMail, title: "Speed Up Mail",
                        summary: "Compact Mail's message database and reindex messages for faster search. Quit Mail first.",
                        symbol: "envelope", needsAdmin: false, recommended: false),
    ]

    /// Tasks this Mac can run: periodic scripts were removed in macOS 14, Mail needs Full Disk Access and a Mail database.
    public static func available(hasFullDiskAccess: Bool = Permissions.hasFullDiskAccess) -> [MaintenanceTask] {
        all.filter { task in
            switch task.id {
            case .periodicScripts:
                return ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 14 && FileManager.default.fileExists(atPath: "/usr/sbin/periodic")
            case .speedUpMail:
                return hasFullDiskAccess && MailDatabase.envelopeIndex() != nil
            default:
                return true
            }
        }
    }

    /// Shell command run as root for admin tasks.
    var rootCommand: String? {
        switch id {
        case .freeUpRAM: "/usr/sbin/purge"
        case .flushDNS: "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        case .reindexSpotlight: "/usr/bin/mdutil -E /"
        case .repairPermissions: "/usr/sbin/diskutil resetUserPermissions / \(getuid())"
        case .periodicScripts: "/usr/sbin/periodic daily weekly monthly"
        case .thinSnapshots, .speedUpMail: nil
        }
    }
}

public struct MaintenanceResult: Sendable, Identifiable {
    public var task: MaintenanceTask
    public var error: String?
    /// Extra outcome detail, e.g. memory or space freed.
    public var detail: String?
    public var id: MaintenanceTask.ID { task.id }
    public var succeeded: Bool { error == nil }
}

public enum MaintenanceError: LocalizedError {
    case cancelledByUser
    case failed(String)
    case appRunning(String)

    public var errorDescription: String? {
        switch self {
        case .cancelledByUser: "Administrator authorization was cancelled."
        case .failed(let message): message
        case .appRunning(let app): "Quit \(app) and try again."
        }
    }
}

/// Runs maintenance tasks: user-level ones directly, root-level ones together under one admin prompt.
public enum MaintenanceRunner {
    public static func run(_ tasks: [MaintenanceTask], isAppRunning: (String) -> Bool = { _ in false },
                           progress: @Sendable (MaintenanceTask) -> Void = { _ in }) -> [MaintenanceResult] {
        var results: [MaintenanceResult] = []
        let memoryBefore = MemoryStats.current()

        let rootTasks = tasks.filter(\.needsAdmin)
        if !rootTasks.isEmpty {
            rootTasks.forEach(progress)
            do {
                try runAsAdmin(rootTasks)
                for task in rootTasks {
                    var detail: String?
                    if task.id == .freeUpRAM, let before = memoryBefore, let after = MemoryStats.current() {
                        let freed = after.free - before.free
                        detail = freed > 0 ? "\(ByteCountFormatter.string(fromByteCount: freed, countStyle: .memory)) of memory freed" : nil
                    }
                    if task.id == .reindexSpotlight { detail = "Spotlight keeps indexing in the background for a while" }
                    results.append(MaintenanceResult(task: task, error: nil, detail: detail))
                }
            } catch {
                results += rootTasks.map { MaintenanceResult(task: $0, error: error.localizedDescription) }
            }
        }

        for task in tasks where !task.needsAdmin {
            progress(task)
            do {
                let detail = try runUserTask(task, isAppRunning: isAppRunning)
                results.append(MaintenanceResult(task: task, error: nil, detail: detail))
            } catch {
                results.append(MaintenanceResult(task: task, error: error.localizedDescription))
            }
        }
        for result in results where result.succeeded { MaintenanceHistory.recordRun(of: result.task.id) }
        return results.sorted { MaintenanceTask.all.firstIndex(of: $0.task)! < MaintenanceTask.all.firstIndex(of: $1.task)! }
    }

    /// One `do shell script … with administrator privileges` for all selected root tasks, so the password is asked once.
    static func runAsAdmin(_ tasks: [MaintenanceTask]) throws {
        let script = tasks.compactMap(\.rootCommand).joined(separator: "; ")
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let output = try ProcessRunner.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"], timeout: 1900)
        guard output.status == 0 else {
            if output.stderr.contains("-128") { throw MaintenanceError.cancelledByUser }
            throw MaintenanceError.failed(output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    static func runUserTask(_ task: MaintenanceTask, isAppRunning: (String) -> Bool) throws -> String? {
        switch task.id {
        case .thinSnapshots:
            let before = LocalSnapshots.list()
            guard !before.isEmpty else { return "No local snapshots to thin" }
            let output = try ProcessRunner.run("/usr/bin/tmutil", ["thinlocalsnapshots", "/", "1073741824", "3"], timeout: 600)
            guard output.status == 0 else { throw MaintenanceError.failed(output.stderr.isEmpty ? "tmutil failed" : output.stderr) }
            let removed = before.count - LocalSnapshots.list().count
            return removed > 0 ? "\(removed) \(removed == 1 ? "snapshot" : "snapshots") removed" : "macOS kept the snapshots it still needs"
        case .speedUpMail:
            guard !isAppRunning("com.apple.mail") else { throw MaintenanceError.appRunning("Mail") }
            return try MailDatabase.compact()
        default:
            return nil
        }
    }
}

/// Local Time Machine snapshots on the startup disk.
enum LocalSnapshots {
    static func list() -> [String] {
        guard let output = try? ProcessRunner.run("/usr/bin/tmutil", ["listlocalsnapshots", "/"], timeout: 30), output.status == 0 else { return [] }
        return String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("com.apple.TimeMachine") }
    }
}

/// Mail's message index: `~/Library/Mail/<version>/MailData/Envelope Index`.
enum MailDatabase {
    static func envelopeIndex() -> URL? {
        let mail = JunkPaths.current.library.appending(path: "Mail")
        let info = NSDictionary(contentsOf: mail.appending(path: "PersistenceInfo.plist"))
        let versions = (info?["LastUsedVersionDirectoryName"] as? String).map { [$0] }
            ?? ((try? FileManager.default.contentsOfDirectory(atPath: mail.path)) ?? []).filter { $0.hasPrefix("V") }.sorted().reversed()
        return versions.lazy.map { mail.appending(path: "\($0)/MailData/Envelope Index") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// VACUUM the index, then let Spotlight reimport messages.
    static func compact() throws -> String? {
        guard let index = envelopeIndex() else { throw MaintenanceError.failed("Mail's database was not found.") }
        let before = FileSizer.allocatedSize(of: index)
        let vacuum = try ProcessRunner.run("/usr/bin/sqlite3", [index.path, "VACUUM;"], timeout: 600)
        guard vacuum.status == 0 else { throw MaintenanceError.failed(vacuum.stderr.isEmpty ? "Could not compact Mail's database." : vacuum.stderr) }
        _ = try? ProcessRunner.run("/usr/bin/mdimport", [JunkPaths.current.library.appending(path: "Mail").path], timeout: 120)
        let saved = before - FileSizer.allocatedSize(of: index)
        return saved > 0 ? "Database reduced by \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))" : "Database compacted"
    }
}

/// Memory statistics from `host_statistics64`.
public struct MemoryStats: Sendable {
    public var free: Int64
    public var used: Int64
    public var total: Int64

    public static func current() -> MemoryStats? {
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(getpagesize())
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let free = (Int64(info.free_count) + Int64(info.inactive_count) + Int64(info.purgeable_count)) * page
        return MemoryStats(free: free, used: total - free, total: total)
    }
}

/// When each task last ran successfully (CleanMyMac only logs this; here it is shown on the task).
public enum MaintenanceHistory {
    private static let key = "maintenance.lastRun"

    public static func lastRun(of id: MaintenanceTask.ID) -> Date? {
        (UserDefaults.standard.dictionary(forKey: key)?[id.rawValue] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func recordRun(of id: MaintenanceTask.ID) {
        var runs = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        runs[id.rawValue] = Date().timeIntervalSince1970
        UserDefaults.standard.set(runs, forKey: key)
    }
}
