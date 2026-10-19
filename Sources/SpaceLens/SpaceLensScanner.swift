import Darwin
import Foundation
import JunkCleanup

public struct SpaceLensProgress: Sendable {
    public var scannedBytes: Int64
    /// Used space of the volume when scanning a whole disk; nil for a folder (size unknown up front).
    public var expectedBytes: Int64?
    public var currentPath: String

    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(scannedBytes) / Double(expectedBytes))
    }
}

/// Builds the size tree for a disk or folder.
///
/// Like CleanMyMac it lists every directory (hidden files and package contents included), counts symlinks as
/// files without following them, uses allocated sizes, stays on the starting volume, and skips the
/// `/System/Volumes/Data` firmlink twin. Unlike it, privacy-protected folders are not opened without Full Disk
/// Access: opening them would block on a consent prompt.
public final class SpaceLensScanner: @unchecked Sendable {
    let hasFullDiskAccess: Bool
    let home: URL
    private let lock = NSLock()
    private var scannedBytes: Int64 = 0
    private var lastReported: Int64 = 0
    private var cancelled = false

    public init(hasFullDiskAccess: Bool = Permissions.hasFullDiskAccess, home: URL = JunkPaths.current.home) {
        self.hasFullDiskAccess = hasFullDiskAccess
        self.home = home
    }

    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// Folders macOS guards with a consent prompt (Files & Folders, App Data, Mail, Safari, iCloud...).
    var privacyProtectedPaths: Set<String> {
        let relative = [
            "Desktop", "Documents", "Downloads", "Pictures/Photos Library.photoslibrary",
            "Library/Mail", "Library/Messages", "Library/Safari", "Library/Containers", "Library/Group Containers",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Application Support/com.apple.TCC", "Library/Application Support/Knowledge",
            "Library/Calendars", "Library/Reminders", "Library/HomeKit", "Library/Cookies", "Library/Suggestions",
            "Library/Mobile Documents", "Library/CloudStorage", "Library/Biome", "Library/IdentityServices",
            "Library/Metadata/CoreSpotlight", "Library/Sharing", "Library/Accounts", "Library/Autosave Information",
        ]
        return Set(relative.map { home.appending(path: $0).standardizedFileURL.path })
    }

    /// Paths that are never deleted from Space Lens, whatever the file permissions say.
    static func isProtectedPath(_ path: String, home: String) -> Bool {
        let roots = ["/", "/System", "/Library", "/Applications", "/Users", "/private", "/usr", "/bin", "/sbin", "/opt", "/cores", "/dev", "/etc", "/var", "/tmp",
                     home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads", home + "/Applications"]
        if roots.contains(path) { return true }
        return ["/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/", "/Library/Apple/"].contains { path.hasPrefix($0) }
            || path == Bundle.main.bundlePath
    }

    public func scan(_ root: URL, progress: @escaping @Sendable (SpaceLensProgress) -> Void = { _ in }) async throws -> SpaceLensNode {
        let root = root.standardizedFileURL
        let expected = Self.usedSpace(ofVolumeAt: root)
        let context = Context(
            skipped: Self.otherMountPoints(besides: root),
            protected: hasFullDiskAccess ? [] : privacyProtectedPaths,
            home: home.standardizedFileURL.path,
            report: { @Sendable [unowned self] path in
                progress(SpaceLensProgress(scannedBytes: self.lock.withLock { self.scannedBytes }, expectedBytes: expected, currentPath: path))
            }
        )
        guard let tree = await scanDirectory(root, depth: 0, context), !isCancelled, !Task.isCancelled else { throw CancellationError() }
        let rootName = root.path == "/" ? "Macintosh HD" : FileManager.default.displayName(atPath: root.path)
        var children = tree.children
        if let purgeable = Self.purgeableSpace(ofVolumeAt: root), purgeable > 0 {
            children.append(SpaceLensNode(name: "Purgeable Space", path: root.path + "#purgeable", kind: .purgeable, size: purgeable))
        }
        return SpaceLensNode(name: rootName, path: root.path, kind: .directory, cloud: tree.cloud, isProtected: true, children: children)
    }

    /// Reads the contents of a folder that was collapsed during the scan, when the user opens it.
    public func expand(_ node: SpaceLensNode) async {
        guard node.isCollapsed else { return }
        let context = Context(skipped: Self.otherMountPoints(besides: node.url), protected: hasFullDiskAccess ? [] : privacyProtectedPaths,
                              home: home.standardizedFileURL.path, report: { _ in })
        if let scanned = await scanDirectory(node.url, depth: 0, context, collapse: false) {
            await MainActor.run { node.adoptChildren(of: scanned) }
        }
    }

    /// Children beyond this many per folder are folded into one "smaller items" entry. Space Lens shows at most
    /// 38 bubbles per level, so nothing visible is lost while memory stays bounded on large disks.
    static let maxChildrenPerFolder = 64
    /// Folders smaller than this keep their size but not their contents (read again on demand), which keeps a
    /// whole-disk tree to a few hundred thousand nodes instead of millions.
    static let collapseBelowBytes: Int64 = 1_000_000
    /// Subfolders of one folder scanned at the same time.
    static let subfolderConcurrency = 4

    struct Context: Sendable {
        var skipped: Set<String>
        var protected: Set<String>
        var home: String
        var report: @Sendable (String) -> Void
    }

    /// Recursive traversal; every subfolder is a child task, so the cooperative pool load-balances deep trees.
    private func scanDirectory(_ url: URL, depth: Int, _ context: Context, collapse: Bool = true) async -> SpaceLensNode? {
        if isCancelled || Task.isCancelled { return nil }
        let (files, directories, placeholders) = readEntries(of: url, context)

        // At most `subfolderConcurrency` subfolders per folder are in flight, as in CleanMyMac. Creating a
        // task per subfolder up front would keep hundreds of thousands of pending tasks alive on a full disk.
        let subtrees: [SpaceLensNode] = await withTaskGroup(of: SpaceLensNode?.self) { group in
            var pending = directories.makeIterator()
            for _ in 0..<Self.subfolderConcurrency {
                guard let directory = pending.next() else { break }
                group.addTask { await self.scanDirectory(directory, depth: depth + 1, context) }
            }
            var nodes: [SpaceLensNode] = []
            for await node in group {
                if let node { nodes.append(node) }
                if let directory = pending.next() {
                    group.addTask { await self.scanDirectory(directory, depth: depth + 1, context) }
                }
            }
            return nodes
        }

        var flags = stat()
        let hasFlags = lstat(url.path, &flags) == 0
        let restricted = hasFlags && flags.st_flags & UInt32(SF_RESTRICTED) != 0
        let isDataless = hasFlags && flags.st_flags & UInt32(SF_DATALESS) != 0
        let isProtected = restricted || Self.isProtectedPath(url.path, home: context.home)

        // Decide on collapsing from raw sizes first, so small folders never allocate a node per file.
        let total = files.reduce(Int64(0)) { $0 + $1.size } + subtrees.reduce(Int64(0)) { $0 + $1.size }
        let hasSpared = files.contains(where: \.mustBeSpared) || subtrees.contains(where: \.containsSparedItems) || !placeholders.isEmpty
        if collapse, depth > 1, total < Self.collapseBelowBytes, !hasSpared, !isProtected, !(files.isEmpty && subtrees.isEmpty) {
            return SpaceLensNode.collapsedFolder(name: url.lastPathComponent, size: total, cloud: isDataless ? .evicted : .notCloud)
        }

        let fileNodes = files.map { SpaceLensNode(name: $0.name, kind: .file, size: $0.size, cloud: $0.cloud, isProtected: $0.isProtected) }
        let children = Self.foldingSmallItems(fileNodes + subtrees) + placeholders
        let allEvicted = !children.isEmpty && children.allSatisfy { $0.cloud == .evicted }
        let cloud: SpaceLensNode.CloudStatus = isDataless || allEvicted ? .evicted : (Self.isInCloudFolder(url.path, home: context.home) ? .local : .notCloud)
        return SpaceLensNode(name: url.lastPathComponent, kind: .directory, cloud: cloud, isProtected: isProtected, children: children)
    }

    struct RawFile {
        var name: String
        var size: Int64
        var cloud: SpaceLensNode.CloudStatus
        var isProtected: Bool
        var mustBeSpared: Bool { isProtected || cloud == .evicted }
    }

    private func readEntries(of url: URL, _ context: Context) -> (files: [RawFile], directories: [URL], placeholders: [SpaceLensNode]) {
        let entries = DirectoryReader.entries(at: url.path) ?? []
        var files: [RawFile] = []
        var directories: [URL] = []
        var placeholders: [SpaceLensNode] = []
        let base = url.path == "/" ? "" : url.path

        for entry in entries {
            let name = entry.name
            let path = base + "/" + name
            if context.skipped.contains(path) || path.hasPrefix("/System/Volumes/Data/") || path == "/System/Volumes/Data"
                || path == "/.nofollow" || path.hasPrefix("/.nofollow/") || path == "/Volumes" || path == "/dev" { continue }
            if context.protected.contains(path) {
                placeholders.append(SpaceLensNode(name: name, kind: .needsAccess, isProtected: true))
                continue
            }
            switch entry.kind {
            case .directory:
                directories.append(URL(fileURLWithPath: path, isDirectory: true))
            case .file, .symlink:
                let cloud: SpaceLensNode.CloudStatus = entry.flags & UInt32(SF_DATALESS) != 0 ? .evicted : (Self.isInCloudFolder(path, home: context.home) ? .local : .notCloud)
                let restricted = entry.flags & UInt32(SF_RESTRICTED) != 0
                files.append(RawFile(name: name, size: entry.allocatedSize, cloud: cloud,
                                     isProtected: restricted || Self.isProtectedPath(path, home: context.home)))
                add(entry.allocatedSize, path: path, report: context.report)
            case .other:
                break // Sockets, FIFOs and devices take no space.
            }
        }
        return (files, directories, placeholders)
    }

    /// Keeps the largest children and folds the rest into one entry that remembers their names. Anything that
    /// must survive a delete (cloud-only, protected, unread) is never folded, so the planner still sees it.
    static func foldingSmallItems(_ children: [SpaceLensNode]) -> [SpaceLensNode] {
        guard children.count > maxChildrenPerFolder else { return children }
        let sorted = children.sorted { $0.size > $1.size }
        let kept = Array(sorted.prefix(maxChildrenPerFolder))
        let rest = sorted.dropFirst(maxChildrenPerFolder)
        let mustStay = rest.filter(\.containsSparedItems)
        let folded = rest.filter { !$0.containsSparedItems }
        guard !folded.isEmpty else { return children }
        let total = folded.reduce(Int64(0)) { $0 + $1.size }
        return kept + mustStay + [SpaceLensNode(name: "…smaller items", kind: .smallerFiles, size: total, foldedNames: folded.map(\.name))]
    }

    private func add(_ bytes: Int64, path: String, report: (String) -> Void) {
        let shouldReport: Bool = lock.withLock {
            scannedBytes += bytes
            guard scannedBytes - lastReported > 256_000_000 else { return false }
            lastReported = scannedBytes
            return true
        }
        if shouldReport { report(path) }
    }

    static func isInCloudFolder(_ path: String, home: String) -> Bool {
        path.hasPrefix(home + "/Library/Mobile Documents/") || path.hasPrefix(home + "/Library/CloudStorage/")
    }

    /// Other mounted volumes inside the scanned tree; the scan never crosses into them.
    static func otherMountPoints(besides root: URL) -> Set<String> {
        let rootVolume = (try? root.resourceValues(forKeys: [.volumeURLKey]))?.volume?.standardizedFileURL.path
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        return Set(volumes.map(\.standardizedFileURL.path).filter { $0 != rootVolume && $0 != "/" && $0 != "/private/var/vm" })
    }

    /// Bytes in use on a volume, but only when the whole volume is scanned (otherwise progress is indeterminate).
    static func usedSpace(ofVolumeAt url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              values.volume?.standardizedFileURL.path == url.path,
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return nil }
        return Int64(total - available)
    }

    /// Space the system can reclaim on demand (snapshots, caches): "important usage" capacity minus plain free space.
    static func purgeableSpace(ofVolumeAt url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsEjectableKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              values.volume?.standardizedFileURL.path == url.path, values.volumeIsEjectable != true,
              let important = values.volumeAvailableCapacityForImportantUsage, let available = values.volumeAvailableCapacity
        else { return nil }
        return important - Int64(available)
    }
}
