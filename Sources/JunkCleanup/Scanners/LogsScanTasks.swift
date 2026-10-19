import Foundation

/// Files of 10 KiB or less are not worth listing.
private let minimumLogSize: Int64 = 10 * 1024

private enum LogScanning {
    /// A log file must be openable for writing (so it can be truncated or removed).
    static func isWritable(_ url: URL, isDirectory: Bool) -> Bool {
        isDirectory || FileManager.default.isWritableFile(atPath: url.path)
    }

    static func logicalSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    /// A file root becomes one item; a folder becomes one item sized by its qualifying files.
    static func item(for root: URL, _ context: ScanContext, minimumSize: Int64) -> JunkItem? {
        guard context.canRemove(root) else { return nil }
        let isDirectory = context.isDirectory(root)
        guard isWritable(root, isDirectory: isDirectory) else { return nil }

        if !isDirectory {
            guard logicalSize(root) > minimumSize else { return nil }
            return JunkItem(name: displayName(root), url: root, size: context.size(of: root), isAutoSelected: true, action: .truncateOrDelete(root))
        }

        var size: Int64 = 0
        var count = 0
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            if context.isDirectory(file) || file.lastPathComponent == ".DS_Store" || context.ignore.isIgnored(file) { continue }
            guard logicalSize(file) > minimumSize, isWritable(file, isDirectory: false) else { continue }
            size += context.size(of: file)
            count += 1
        }
        guard count > 0 else { return nil }
        return JunkItem(
            name: displayName(root),
            detail: count == 1 ? "1 file" : "\(count) files",
            url: root,
            size: size,
            isAutoSelected: true,
            action: .truncateOrDelete(root)
        )
    }

    /// Log folders are usually named after a bundle id; show the app name when it resolves.
    static func displayName(_ url: URL) -> String {
        let raw = url.deletingPathExtension().lastPathComponent
        return raw.contains(".") ? AppNames.displayName(forBundleIdentifier: raw) : raw
    }
}

/// ~/Library/Logs/*, container logs, and the LaunchServices download (quarantine) history.
struct UserLogsScanTask: JunkScanTask {
    let identifier = "userLogs"
    let title = "User logs"
    let group = JunkGroupID.userLogs

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let paths = context.paths
        var user: [JunkItem] = []
        for root in context.children(of: paths.userLogs) {
            try Task.checkCancellation()
            if let item = LogScanning.item(for: root, context, minimumSize: minimumLogSize) { user.append(item) }
        }

        var sandboxed: [JunkItem] = []
        for container in context.children(of: paths.containers) {
            for root in context.children(of: container.appending(path: "Data/Library/Logs")) {
                try Task.checkCancellation()
                if let item = LogScanning.item(for: root, context, minimumSize: minimumLogSize) { sandboxed.append(item) }
            }
        }

        var quarantine: [JunkItem] = []
        for name in ["com.apple.LaunchServices.QuarantineEventsV2", "com.apple.LaunchServices.QuarantineEvents"] {
            let url = paths.userPreferences.appending(path: name)
            guard context.exists(url), !context.ignore.isIgnored(url), context.canRemove(url) else { continue }
            let size = context.size(of: url)
            guard size > 0 else { continue }
            quarantine.append(JunkItem(name: "Download history", detail: name, url: url, size: size, isAutoSelected: true, action: .delete(url)))
        }

        return [
            JunkSubgroup(id: "userLogs.user", title: "App Logs", items: user.sorted { $0.size > $1.size }),
            JunkSubgroup(id: "userLogs.sandbox", title: "Sandboxed App Logs", items: sandboxed.sorted { $0.size > $1.size }),
            JunkSubgroup(id: "userLogs.quarantine", title: "Download History", items: quarantine),
        ].filter { !$0.items.isEmpty }
    }
}

/// /Library/Logs/* and a fixed set of files in /private/var/log. Never touches the unified log store.
struct SystemLogsScanTask: JunkScanTask {
    let identifier = "systemLogs"
    let title = "System logs"
    let group = JunkGroupID.systemLogs

    private static let knownPrivateLogs = [
        "system.log", "install.log", "wifi.log", "fsck_apfs.log", "fsck_apfs_error.log", "fsck_hfs.log",
        "daily.out", "weekly.out", "monthly.out", "cups", "DiagnosticMessages",
    ]
    private static let rotatedArchive = try! NSRegularExpression(pattern: #"^(system\.log\.\d+\.gz|wifi\.log\.\d+\.bz2)$"#, options: .caseInsensitive)

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        var local: [JunkItem] = []
        for root in context.children(of: URL(fileURLWithPath: "/Library/Logs")) {
            try Task.checkCancellation()
            if let item = LogScanning.item(for: root, context, minimumSize: minimumLogSize) { local.append(item) }
        }

        let varLog = URL(fileURLWithPath: "/private/var/log")
        var roots = Self.knownPrivateLogs.map { varLog.appending(path: $0) }.filter(context.exists)
        roots += context.children(of: varLog).filter { url in
            let name = url.lastPathComponent
            return Self.rotatedArchive.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        var privateLogs: [JunkItem] = []
        for root in roots where !context.ignore.isIgnored(root) {
            try Task.checkCancellation()
            if let item = LogScanning.item(for: root, context, minimumSize: minimumLogSize) { privateLogs.append(item) }
        }

        return [
            JunkSubgroup(id: "systemLogs.local", title: "Library Logs", items: local.sorted { $0.size > $1.size }),
            JunkSubgroup(id: "systemLogs.private", title: "System Logs", items: privateLogs.sorted { $0.size > $1.size }),
        ].filter { !$0.items.isEmpty }
    }
}
