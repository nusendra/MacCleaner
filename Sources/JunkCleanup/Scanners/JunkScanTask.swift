import Foundation

/// One unit of scanning work. Tasks run concurrently; results with the same `group` are merged.
public protocol JunkScanTask: Sendable {
    var identifier: String { get }
    var title: String { get }
    var group: JunkGroupID { get }
    /// Watchdog limit; slow tasks (Spotlight, simctl) get longer.
    var timeout: Duration { get }
    func scan(_ context: ScanContext) async throws -> [JunkSubgroup]
}

extension JunkScanTask {
    public var timeout: Duration { .seconds(60) }
}

/// Every task, in the order the results are presented.
public enum JunkScanTasks {
    public static func all(includeSystemWide: Bool = true) -> [any JunkScanTask] {
        var tasks: [any JunkScanTask] = [
            BrokenPreferencesScanTask(),
            UserLogsScanTask(),
            DocumentVersionsScanTask(),
            UserCachesScanTask(),
        ]
        tasks += XcodeJunkScanTasks.all
        tasks += [TrashesScanTask(), MountedTrashesScanTask()]
        if includeSystemWide {
            tasks += [
                DeletedUsersScanTask(),
                BrokenLaunchAgentsScanTask(),
                SystemLogsScanTask(),
                MobileBackupsScanTask(),
                ApplicationLanguagesScanTask(),
                SystemCachesScanTask(),
                UniversalBinariesScanTask(),
            ]
        }
        return tasks
    }
}
