import Foundation

/// Decides whether a directory entry belongs to an app, by bundle id and by name.
struct ResourceMatcher: Sendable {
    let bundleID: String?
    let name: String
    private let lowerBundleID: String?
    private let lowerName: String
    private let nameWords: Set<String>
    private let matchesByName: Bool

    /// Folder names shared by many apps or by the system; never attributed to one app.
    static let sharedNames: Set<String> = [
        "apple", "google", "microsoft", "adobe", "mozilla", "jetbrains", "macromedia", "oracle", "java",
        "application support", "caches", "preferences", "logs", "containers", "group containers", "launchagents",
        "launchdaemons", "cookies", "saved application state", "webkit", "crashreporter", "diagnosticreports",
        "frameworks", "fonts", "keychains", "mail", "messages", "safari", "icloud", "mobile documents",
        "cloudstorage", "developer", "printers", "audio", "plug-ins", "internet plug-ins", "services", "spotlight",
        "quicklook", "screen savers", "extensions", "staging", "updates", "temp", "tmp", "data", "cache",
        ".ds_store", ".localized",
    ]

    /// App names too generic to match on their own (an app called "Notes" must not claim a folder called "Notes").
    static let genericNames: Set<String> = [
        "app", "mac", "helper", "agent", "service", "launcher", "updater", "update", "installer", "uninstaller",
        "notes", "music", "photos", "mail", "calendar", "messages", "settings", "preferences", "data", "cache",
        "files", "documents", "downloads", "desktop", "library", "support", "tools", "utility", "utilities",
        "player", "viewer", "editor", "browser", "terminal", "console", "monitor", "manager",
    ]

    init(bundleID: String?, name: String) {
        self.bundleID = bundleID
        self.name = name
        lowerBundleID = bundleID?.lowercased()
        lowerName = name.lowercased()
        nameWords = Set(Self.words(lowerName, separators: "._ "))
        // Name matching is skipped when it would duplicate the bundle-id match or is too generic.
        matchesByName = bundleID != name && !nameWords.isEmpty && !Self.genericNames.contains(lowerName) && lowerName.count >= 3
    }

    static func words(_ text: String, separators: String) -> [String] {
        text.split(whereSeparator: { separators.contains($0) }).map(String.init).filter { !$0.isEmpty }
    }

    /// Matching rule for an entry directly inside a searched folder.
    func matches(entryName: String, isDirectory: Bool) -> Bool {
        let full = entryName.lowercased()
        let base = isDirectory ? full : ((full as NSString).deletingPathExtension)
        if Self.sharedNames.contains(base) || Self.sharedNames.contains(full) { return false }
        if base.hasPrefix("com.apple."), !(lowerBundleID?.hasPrefix("com.apple.") ?? false) { return false }

        if let id = lowerBundleID, id != lowerName, !isOtherVersion(base, of: id), containsOnBoundary(full, id) {
            return true
        }
        if matchesByName, !isOtherVersion(base, of: lowerName) {
            return nameWords.isSubset(of: Set(Self.words(base, separators: " ")))
        }
        return false
    }

    /// Preferences: every `.` component of the bundle id (or `._ ` word of the name) appears in the plist's name.
    func matchesPreference(fileName: String) -> Bool {
        var key = fileName.lowercased()
        if key.hasSuffix(".plist") { key.removeLast(".plist".count) }
        if key.hasPrefix("com.apple."), !(lowerBundleID?.hasPrefix("com.apple.") ?? false) { return false }
        if let id = lowerBundleID, !isOtherVersion(key, of: id) {
            let components = Set(Self.words(id, separators: "."))
            if !components.isEmpty, components.isSubset(of: Set(Self.words(key, separators: "."))) { return true }
        }
        if matchesByName, !isOtherVersion(key, of: lowerName) {
            return nameWords.isSubset(of: Set(Self.words(key, separators: "._ ")))
        }
        return false
    }

    /// "Foo 2", "Foo2" or "com.foo.app2" belong to another major version of "Foo"/"com.foo.app".
    func isOtherVersion(_ candidate: String, of reference: String) -> Bool {
        guard candidate.hasPrefix(reference) else { return false }
        return candidate.dropFirst(reference.count).contains(where: \.isNumber)
    }

    /// Substring match that does not end in the middle of a word, so `com.foo.app` does not claim `com.foo.application`.
    func containsOnBoundary(_ haystack: String, _ needle: String) -> Bool {
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let range = haystack.range(of: needle, range: searchRange) {
            let after = range.upperBound == haystack.endIndex ? nil : haystack[range.upperBound]
            let before = range.lowerBound == haystack.startIndex ? nil : haystack[haystack.index(before: range.lowerBound)]
            let isBoundary: (Character?) -> Bool = { $0 == nil || !($0!.isLetter || $0!.isNumber) }
            if isBoundary(after) && isBoundary(before) { return true }
            searchRange = range.upperBound..<haystack.endIndex
        }
        return false
    }
}
