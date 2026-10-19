import Foundation

/// Groups cache entries by owner (bundle id or container name) into subgroups.
private struct CacheGroups {
    private var order: [String] = []
    private var items: [String: [JunkItem]] = [:]

    mutating func add(_ item: JunkItem, owner: String) {
        if items[owner] == nil { order.append(owner) }
        items[owner, default: []].append(item)
    }

    func subgroups() -> [JunkSubgroup] {
        order.compactMap { owner in
            guard let entries = items[owner], !entries.isEmpty else { return nil }
            return JunkSubgroup(
                id: owner,
                title: AppNames.displayName(forBundleIdentifier: owner),
                bundleIdentifier: owner.contains(".") ? owner : nil,
                items: entries.sorted { $0.size > $1.size }
            )
        }
    }
}

private func cacheItem(_ url: URL, _ context: ScanContext, selected: Bool = true, owner: String? = nil) -> JunkItem? {
    guard context.canRemove(url) else { return nil }
    let size = context.size(of: url)
    guard size > 0 else { return nil }
    let quit = owner.map { Set([$0]) } ?? []
    return JunkItem(name: url.lastPathComponent, url: url, size: size, isAutoSelected: selected, action: .delete(url), quitBeforeCleaning: quit)
}

/// ~/Library/Caches, $DARWIN_USER_CACHE_DIR, sandbox container caches, plus app-specific cache locations.
struct UserCachesScanTask: JunkScanTask {
    let identifier = "userCaches"
    let title = "User caches"
    let group = JunkGroupID.userCaches

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        var groups = CacheGroups()
        let paths = context.paths

        // Each immediate child of a caches folder is one item, owned by its folder name.
        var roots = [paths.userCaches]
        if let darwin = paths.darwinUserCacheDirectory { roots.append(darwin) }
        for root in roots {
            for url in context.children(of: root) {
                try Task.checkCancellation()
                if let item = cacheItem(url, context, owner: url.lastPathComponent) { groups.add(item, owner: url.lastPathComponent) }
            }
        }

        // ~/Library/Containers/<id>/Data/Library/Caches/* grouped by container.
        for container in context.children(of: paths.containers) {
            let caches = container.appending(path: "Data/Library/Caches")
            for url in context.children(of: caches) {
                try Task.checkCancellation()
                let owner = container.lastPathComponent
                if let item = cacheItem(url, context, owner: owner) { groups.add(item, owner: owner) }
            }
        }

        for app in InstalledApps.all(home: paths.home) where isElectron(app.url) {
            let cache = paths.applicationSupport.appending(path: "\(app.name)/Cache")
            guard context.exists(cache), !context.ignore.isIgnored(cache) else { continue }
            let owner = app.bundleIdentifier ?? app.name
            if let item = cacheItem(cache, context, owner: owner) { groups.add(item, owner: owner) }
        }

        addAppStorePurgeables(context, into: &groups)
        addSpotify(context, into: &groups)
        addGradle(context, into: &groups)
        addKnownAppCaches(context, into: &groups)
        return groups.subgroups()
    }

    private func isElectron(_ app: URL) -> Bool {
        FileManager.default.fileExists(atPath: app.appending(path: "Contents/Frameworks/Electron Framework.framework").path)
    }

    /// The App Store lists finished downloads it no longer needs in its cache manifest.
    private func addAppStorePurgeables(_ context: ScanContext, into groups: inout CacheGroups) {
        guard let darwin = context.paths.darwinUserCacheDirectory else { return }
        let manifest = darwin.appending(path: "com.apple.appstore/manifest.plist")
        guard let info = NSDictionary(contentsOf: manifest), let purgeables = info["purgeables"] as? [Any] else { return }
        for case let path as String in purgeables {
            let url = URL(fileURLWithPath: path)
            if context.exists(url), let item = cacheItem(url, context) { groups.add(item, owner: "com.apple.appstore") }
        }
    }

    private func addSpotify(_ context: ScanContext, into groups: inout CacheGroups) {
        let support = context.paths.applicationSupport.appending(path: "Spotify")
        guard let prefs = try? String(contentsOf: support.appending(path: "prefs"), encoding: .utf8) else { return }
        let storage = ["storage.last-location=\"", "storage.location=\""].lazy.compactMap { key -> URL? in
            guard let start = prefs.range(of: key), let end = prefs[start.upperBound...].firstIndex(of: "\"") else { return nil }
            return URL(fileURLWithPath: String(prefs[start.upperBound..<end]))
        }.first ?? support.appending(path: "PersistentCache/Storage")
        guard context.exists(storage), !context.ignore.isIgnored(storage) else { return }
        if let item = cacheItem(storage, context, selected: false, owner: "com.spotify.client") { groups.add(item, owner: "com.spotify.client") }
    }

    private func addGradle(_ context: ScanContext, into groups: inout CacheGroups) {
        for url in context.children(of: context.paths.home.appending(path: ".gradle/caches")) {
            if let item = cacheItem(url, context, selected: false) { groups.add(item, owner: "Gradle") }
        }
    }

    /// Media caches of chat/video apps: shown, never preselected (they hold the user's downloaded media).
    private func addKnownAppCaches(_ context: ScanContext, into groups: inout CacheGroups) {
        let home = context.paths.home
        let known: [(owner: String, path: String)] = [
            ("org.telegram.desktop", "Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/cache"),
            ("org.telegram.desktop", "Library/Containers/org.telegram.desktop/Data/Library/Application Support/Telegram Desktop/tdata/user_data/media_cache"),
            ("com.tdesktop.Telegram", "Library/Application Support/Telegram Desktop/tdata/user_data/cache"),
            ("com.tdesktop.Telegram", "Library/Application Support/Telegram Desktop/tdata/user_data/media_cache"),
            ("com.tencent.tenvideo", "Library/Containers/com.tencent.tenvideo/Data/Library/Application Support/Download/video"),
            ("com.tencent.QQMusicMac", "Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac/iMusic"),
            ("com.youku.mac", "Library/Containers/com.youku.mac/Data/Documents/YTCORE_PLAYER_CACHE"),
            ("Adobe Media Cache", "Library/Application Support/Adobe/Common/Media Cache Files"),
        ]
        for entry in known {
            let url = home.appending(path: entry.path)
            guard context.exists(url), !context.ignore.isIgnored(url) else { continue }
            if let item = cacheItem(url, context, selected: false, owner: entry.owner) { groups.add(item, owner: entry.owner) }
        }

        // Photos keeps old desktop renderings; everything but the most recently used one is junk.
        let photos = home.appending(path: "Library/Containers/com.apple.Photos/Data/Library/Application Support/Photos Desktop/0")
        let entries = context.children(of: photos)
        let newest = entries.max { accessDate($0) < accessDate($1) }
        for url in entries where url != newest {
            if let item = cacheItem(url, context, owner: "com.apple.Photos") { groups.add(item, owner: "com.apple.Photos") }
        }
    }

    private func accessDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate ?? .distantPast
    }
}

/// /Library/Caches — only entries the current user may delete are offered.
struct SystemCachesScanTask: JunkScanTask {
    let identifier = "systemCaches"
    let title = "System caches"
    let group = JunkGroupID.systemCaches

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        var groups = CacheGroups()
        for url in context.children(of: URL(fileURLWithPath: "/Library/Caches")) {
            try Task.checkCancellation()
            if let item = cacheItem(url, context, owner: url.lastPathComponent) { groups.add(item, owner: url.lastPathComponent) }
        }
        return groups.subgroups()
    }
}
