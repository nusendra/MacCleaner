import Foundation

/// User-maintained list of paths and names the scanners must skip. Persisted in UserDefaults.
public final class IgnoreList: @unchecked Sendable {
    public static let shared = IgnoreList()

    private let defaults: UserDefaults
    private let key = "junkCleanup.ignoredItems"
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var entries: Set<String> {
        lock.withLock { Set(defaults.stringArray(forKey: key) ?? []) }
    }

    public func add(_ entry: String) {
        lock.withLock {
            var current = Set(defaults.stringArray(forKey: key) ?? [])
            current.insert(entry)
            defaults.set(current.sorted(), forKey: key)
        }
    }

    public func remove(_ entry: String) {
        lock.withLock {
            var current = Set(defaults.stringArray(forKey: key) ?? [])
            current.remove(entry)
            defaults.set(current.sorted(), forKey: key)
        }
    }

    /// Snapshot used during one scan, so every scanner sees the same list.
    public func snapshot() -> IgnoreSnapshot { IgnoreSnapshot(entries: entries) }
}

public struct IgnoreSnapshot: Sendable {
    public var entries: Set<String>

    public init(entries: Set<String> = []) {
        self.entries = entries
    }

    /// Ignored if the full path, any ancestor path, or the bare name/bundle id is listed.
    public func isIgnored(_ url: URL) -> Bool {
        if entries.contains(url.lastPathComponent) { return true }
        var path = url.standardizedFileURL.path
        while path.count > 1 {
            if entries.contains(path) { return true }
            path = (path as NSString).deletingLastPathComponent
        }
        return false
    }

    public func isIgnored(name: String) -> Bool { entries.contains(name) }
}
