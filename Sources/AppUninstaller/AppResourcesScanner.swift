import Darwin
import Foundation
import JunkCleanup
import Security

/// Collects every file that belongs to one app, grouped like CleanMyMac's app detail view.
public struct AppResourcesScanner: Sendable {
    public var paths: JunkPaths
    public var ignore: IgnoreSnapshot
    /// Dock tiles read once per scan (`defaults export com.apple.dock`), keyed by app path.
    public var dockAppPaths: Set<String>

    public init(paths: JunkPaths = .current, ignore: IgnoreSnapshot = IgnoreList.shared.snapshot(), dockAppPaths: Set<String> = DockTiles.appPaths()) {
        self.paths = paths
        self.ignore = ignore
        self.dockAppPaths = dockAppPaths
    }

    public func resources(for app: InstalledApplication) -> [AppResource] {
        let matcher = ResourceMatcher(bundleID: app.bundleIdentifier, name: app.name)
        var found: [AppResource] = []
        var seen = Set<String>()
        func add(_ resource: AppResource?) {
            guard let resource, !ignore.isIgnored(resource.url), seen.insert(resource.path).inserted else { return }
            found.append(resource)
        }

        if let bundle = app.url {
            let removable = !app.isSystem && !app.isAppStore && FileManager.default.isDeletableFile(atPath: bundle.path) && bundle.path != Bundle.main.bundlePath
            let note = app.isAppStore ? "App Store apps are removed with Launchpad or Finder."
                : app.isSystem ? "Protected system app. Remove its files to reset it." : nil
            add(AppResource(path: bundle.path, group: .binaries, size: FileSizer.allocatedSize(of: bundle), isRemovable: removable, removal: .trash(bundle), note: note))
        }

        let lib = paths.library
        let local = URL(fileURLWithPath: "/Library")
        searchChildren(of: [lib.appending(path: "Application Support"), local.appending(path: "Application Support")], matcher, group: .supportingFiles).forEach(add)
        var cacheRoots = [paths.userCaches]
        if let darwin = paths.darwinUserCacheDirectory { cacheRoots.append(darwin) }
        searchChildren(of: cacheRoots, matcher, group: .caches).forEach(add)
        searchChildren(of: [paths.temporaryDirectory], matcher, group: .caches).forEach(add)
        searchChildren(of: [lib.appending(path: "Logs"), local.appending(path: "Logs")], matcher, group: .logs).forEach(add)
        searchChildren(of: [lib.appending(path: "PDF Services"), local.appending(path: "PDF Services")], ResourceMatcher(bundleID: nil, name: app.name), group: .plugins).forEach(add)
        searchChildren(of: [lib, local], matcher, group: .userData).forEach(add)
        preferences(matcher, roots: [paths.userPreferences, local.appending(path: "Preferences")]).forEach(add)
        exactItems(for: app).forEach(add)
        crashReports(for: app).forEach(add)
        launchAgents(for: app).forEach(add)
        loginItemHelpers(for: app).forEach(add)
        plugins(for: app).forEach(add)
        downloadedInstallers(for: app).forEach(add)
        packageFiles(for: app).forEach(add)
        if let bundle = app.url, dockAppPaths.contains(bundle.path) {
            add(AppResource(path: bundle.path + "#dock", group: .dockIcon, size: 0, removal: .dockTile(appPath: bundle.path)))
        }
        return found
    }

    // MARK: Fetchers

    /// Depth-1 entries of each root that the matcher attributes to the app. Symlinks are listed but not followed.
    func searchChildren(of roots: [URL], _ matcher: ResourceMatcher, group: ResourceGroup) -> [AppResource] {
        roots.flatMap { root -> [AppResource] in
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
            return entries.compactMap { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
                guard url.lastPathComponent != root.lastPathComponent, matcher.matches(entryName: url.lastPathComponent, isDirectory: isDirectory) else { return nil }
                return fileResource(url, group: group)
            }
        }
    }

    func preferences(_ matcher: ResourceMatcher, roots: [URL]) -> [AppResource] {
        roots.flatMap { root -> [AppResource] in
            let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return entries.compactMap { url in
                guard matcher.matchesPreference(fileName: url.lastPathComponent), let resource = fileResource(url, group: .preferences) else { return nil }
                var pref = resource
                if url.pathExtension == "plist" { pref.removal = .preferences(url) }
                return pref
            }
        }
    }

    /// Fixed per-bundle-id locations: sandbox container (and its extensions), group containers, saved state, cookies, help.
    func exactItems(for app: InstalledApplication) -> [AppResource] {
        guard let id = app.bundleIdentifier else { return [] }
        let lib = paths.library
        var items: [AppResource?] = [
            fileResource(lib.appending(path: "Saved Application State/\(id).savedState"), group: .supportingFiles),
            fileResource(lib.appending(path: "Cookies/\(id).binarycookies"), group: .supportingFiles),
            fileResource(lib.appending(path: "HTTPStorages/\(id)"), group: .supportingFiles),
            fileResource(lib.appending(path: "WebKit/\(id)"), group: .supportingFiles),
            fileResource(lib.appending(path: "Preferences/SDMHelpData/Other/\(id).help"), group: .supportingFiles),
            fileResource(lib.appending(path: "Application Scripts/\(id)"), group: .supportingFiles),
        ]
        // The app's own container plus extension containers (`<id>.<extension>`).
        let containers = (try? FileManager.default.contentsOfDirectory(at: lib.appending(path: "Containers"), includingPropertiesForKeys: nil)) ?? []
        items += containers
            .filter { $0.lastPathComponent == id || $0.lastPathComponent.hasPrefix(id + ".") }
            .map { fileResource($0, group: .containers) }
        if let url = app.url {
            items += Self.applicationGroups(of: url).map { fileResource(lib.appending(path: "Group Containers/\($0)"), group: .containers) }
        }
        return items.compactMap { $0 }
    }

    /// `<name>_<date>.crash|diag|hang|spin|ips` in the user and system diagnostic folders.
    func crashReports(for app: InstalledApplication) -> [AppResource] {
        let prefixes = Set([app.name, app.executableName].compactMap { $0 }.map { $0 + "_" })
        let extensions: Set<String> = ["crash", "diag", "hang", "spin", "ips"]
        return [paths.library, URL(fileURLWithPath: "/Library")].flatMap { lib -> [AppResource] in
            ["Logs/DiagnosticReports", "Logs/DiagnosticReports/Retired", "Logs/CrashReporter"].flatMap { relative -> [AppResource] in
                let entries = (try? FileManager.default.contentsOfDirectory(at: lib.appending(path: relative), includingPropertiesForKeys: nil)) ?? []
                return entries.compactMap { url in
                    let name = url.lastPathComponent
                    guard extensions.contains(url.pathExtension.lowercased()), prefixes.contains(where: name.hasPrefix) else { return nil }
                    return fileResource(url, group: .logs)
                }
            }
        }
    }

    /// Launchd jobs tied to the app by `AssociatedBundleIdentifiers`, a label starting with the bundle id,
    /// or a program that lives inside the bundle.
    func launchAgents(for app: InstalledApplication) -> [AppResource] {
        guard let id = app.bundleIdentifier?.lowercased() else { return [] }
        let folders = [paths.library.appending(path: "LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchAgents"), URL(fileURLWithPath: "/Library/LaunchDaemons")]
        let helpers = Set(app.privilegedHelpers.map { $0.lowercased() })
        return folders.flatMap { folder -> [AppResource] in
            let plists = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            return plists.filter { $0.pathExtension.lowercased() == "plist" }.compactMap { url in
                guard let job = NSDictionary(contentsOf: url) as? [String: Any] else { return nil }
                let label = job["Label"] as? String
                let associated: [String] = (job["AssociatedBundleIdentifiers"] as? [String]) ?? [(job["AssociatedBundleIdentifiers"] as? String)].compactMap { $0 }
                let program = (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
                let belongs = associated.contains { $0.lowercased() == id }
                    || label.map { $0.lowercased() == id || $0.lowercased().hasPrefix(id + ".") || helpers.contains($0.lowercased()) } == true
                    || (program != nil && app.url.map { program!.hasPrefix($0.path + "/") } == true)
                guard belongs, var resource = fileResource(url, group: .loginItems) else { return nil }
                resource.removal = .launchAgent(url, label: label)
                return resource
            }
        }
    }

    /// Helpers in `Contents/Library/LoginItems` that launchd currently knows about.
    func loginItemHelpers(for app: InstalledApplication) -> [AppResource] {
        guard let bundle = app.url else { return [] }
        let helpers = (try? FileManager.default.contentsOfDirectory(at: bundle.appending(path: "Contents/Library/LoginItems"), includingPropertiesForKeys: nil)) ?? []
        return helpers.compactMap { helper in
            guard let label = Bundle(url: helper)?.bundleIdentifier,
                  let output = try? ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"], timeout: 5), output.status == 0
            else { return nil }
            return AppResource(path: helper.path, group: .loginItems, size: 0, removal: .loginItemHelper(label: label), note: "Registered as a login item")
        }
    }

    /// Plug-ins shipped inside the bundle that were also copied into the system plug-in folders.
    func plugins(for app: InstalledApplication) -> [AppResource] {
        guard let bundle = app.url else { return [] }
        let pluginExtensions: Set<String> = ["plugin", "webplugin", "component", "bundle", "mdimporter", "qlgenerator", "mailbundle", "service", "workflow", "osax", "prefpane", "saver"]
        var names = Set<String>()
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if pluginExtensions.contains(url.pathExtension.lowercased()) { names.insert(url.lastPathComponent) }
        }
        let folders = ["QuickLook", "Internet Plug-Ins", "Spotlight", "Services", "PreferencePanes", "Screen Savers", "ScriptingAdditions", "Mail/Bundles", "Contextual Menu Items", "Audio/Plug-Ins/Components"]
        return names.flatMap { name in
            folders.flatMap { folder in
                [paths.library, URL(fileURLWithPath: "/Library")].compactMap { fileResource($0.appending(path: "\(folder)/\(name)"), group: .plugins) }
            }
        }
    }

    /// Disk images in ~/Downloads whose name contains every word of the app name.
    func downloadedInstallers(for app: InstalledApplication) -> [AppResource] {
        let words = ResourceMatcher.words(app.name.lowercased(), separators: "._ ")
        guard !words.isEmpty, app.name.count >= 3 else { return [] }
        let downloads = paths.home.appending(path: "Downloads")
        let entries = (try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { url in
            let name = url.lastPathComponent.lowercased()
            guard url.pathExtension.lowercased() == "dmg" || url.pathExtension.lowercased() == "pkg", words.allSatisfy(name.contains) else { return nil }
            return fileResource(url, group: .installers)
        }
    }

    /// Files installed by a package whose identifier is the bundle id (or bundle id + `.pkg`), collapsed to top-level bundles.
    func packageFiles(for app: InstalledApplication) -> [AppResource] {
        guard let id = app.bundleIdentifier?.lowercased(),
              let output = try? ProcessRunner.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: 20), output.status == 0
        else { return [] }
        let packages = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.lowercased() == id || $0.lowercased() == id + ".pkg" }
        return packages.flatMap { package -> [AppResource] in
            let info = (try? ProcessRunner.run("/usr/sbin/pkgutil", ["--pkg-info-plist", package], timeout: 20)).flatMap {
                try? PropertyListSerialization.propertyList(from: $0.stdout, format: nil) as? [String: Any]
            }
            let base = URL(fileURLWithPath: "/").appending(path: (info?["install-location"] as? String) ?? "")
            guard let files = try? ProcessRunner.run("/usr/sbin/pkgutil", ["--only-files", "--files", package], timeout: 30), files.status == 0 else { return [] }
            let topLevel = Set(String(decoding: files.stdout, as: UTF8.self).split(separator: "\n").map { Self.topLevelBundle(of: String($0)) })
            return topLevel.compactMap { relative in
                let url = base.appending(path: relative)
                return fileResource(url, group: url.pathExtension == "app" ? .binaries : .other)
            }
        }
    }

    /// `Applications/Foo.app/Contents/MacOS/foo` → `Applications/Foo.app`; plain files are kept as they are.
    static func topLevelBundle(of path: String) -> String {
        let components = path.split(separator: "/")
        if let index = components.firstIndex(where: { ["app", "prefpane", "plugin", "framework", "bundle", "kext"].contains(($0 as NSString).pathExtension.lowercased()) }) {
            return components[...index].joined(separator: "/")
        }
        return path
    }

    // MARK: Helpers

    /// A resource for an existing path the current user can remove, never one of the shared root folders.
    func fileResource(_ url: URL, group: ResourceGroup) -> AppResource? {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) || (try? url.checkResourceIsReachable()) == true,
              !Self.protectedRoots(home: paths.home).contains(path),
              FileManager.default.isDeletableFile(atPath: path)
        else { return nil }
        return AppResource(path: path, group: group, size: FileSizer.allocatedSize(of: url), removal: .trash(url))
    }

    static func protectedRoots(home: URL) -> Set<String> {
        let relative = ["", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs", "Library/Containers",
                        "Library/Group Containers", "Library/LaunchAgents", "Library/Cookies", "Library/Saved Application State", "Downloads", "Applications"]
        return Set(relative.map { home.appending(path: $0).standardizedFileURL.path } + relative.map { ("/" + $0) as String } + ["/", "/System", "/Users", "/Library/LaunchDaemons"])
    }

    /// App group identifiers from the code signature's entitlements.
    static func applicationGroups(of bundle: URL) -> [String] {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code else { return [] }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let entitlements = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return entitlements["com.apple.security.application-groups"] as? [String] ?? []
    }
}

/// Reads the Dock's persistent tiles.
public enum DockTiles {
    public static func appPaths() -> Set<String> {
        guard let plist = exportDockPlist() else { return [] }
        return Set(["persistent-apps", "persistent-others"].flatMap { key in
            ((plist[key] as? [[String: Any]]) ?? []).compactMap(tilePath)
        })
    }

    static func tilePath(_ tile: [String: Any]) -> String? {
        guard let data = tile["tile-data"] as? [String: Any],
              let file = data["file-data"] as? [String: Any],
              let urlString = file["_CFURLString"] as? String
        else { return nil }
        let path = urlString.hasPrefix("file://") ? URL(string: urlString)?.path : urlString
        return path.map { ($0 as NSString).standardizingPath }
    }

    static func exportDockPlist() -> [String: Any]? {
        let temp = FileManager.default.temporaryDirectory.appending(path: "com.apple.dock.\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let output = try? ProcessRunner.run("/usr/bin/defaults", ["export", "com.apple.dock", temp.path], timeout: 10), output.status == 0 else { return nil }
        return NSDictionary(contentsOf: temp) as? [String: Any]
    }

    /// Removes the tiles pointing at `appPaths` and restarts the Dock so it picks up the change.
    static func remove(appPaths: Set<String>) throws {
        guard var plist = exportDockPlist() else { throw UninstallError.commandFailed("Could not read the Dock settings.") }
        var changed = false
        for key in ["persistent-apps", "persistent-others"] {
            guard let tiles = plist[key] as? [[String: Any]] else { continue }
            let kept = tiles.filter { tilePath($0).map { !appPaths.contains($0) } ?? true }
            if kept.count != tiles.count {
                plist[key] = kept
                changed = true
            }
        }
        guard changed else { return }
        let temp = FileManager.default.temporaryDirectory.appending(path: "com.apple.dock.\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: temp) }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: temp)
        let imported = try ProcessRunner.run("/usr/bin/defaults", ["import", "com.apple.dock", temp.path], timeout: 10)
        guard imported.status == 0 else { throw UninstallError.commandFailed("Could not update the Dock: \(imported.stderr)") }
        _ = try? ProcessRunner.run("/usr/bin/killall", ["Dock"], timeout: 10)
    }
}
