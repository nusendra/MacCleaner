import AppKit
import CoreServices
import Darwin
import Foundation
import JunkCleanup

public enum AppVendor: String, CaseIterable, Sendable {
    case apple = "Apple", microsoft = "Microsoft", adobe = "Adobe", google = "Google", macpaw = "MacPaw", jetbrains = "JetBrains", other = "Other"

    /// First matching bundle-id prefix wins (case-insensitive).
    static func forBundleID(_ bundleID: String?) -> AppVendor {
        guard let id = bundleID?.lowercased() else { return .other }
        let table: [(AppVendor, [String])] = [
            (.apple, ["com.apple", "developer.apple."]),
            (.microsoft, ["com.microsoft.", "com.skype."]),
            (.adobe, ["com.adobe", "adobe."]),
            (.google, ["com.google."]),
            (.macpaw, ["com.macpaw", "com.setapp"]),
            (.jetbrains, ["com.jetbrains", "org.jetbrains"]),
        ]
        return table.first { $0.1.contains { id.hasPrefix($0) } }?.0 ?? .other
    }
}

public enum AppStore: String, Sendable {
    case appStore = "App Store", setapp = "Setapp", other = "Other"
}

/// An installed app, or a "leftover" pseudo-app that only has a bundle id (`url == nil`).
public struct InstalledApplication: Identifiable, Hashable, Sendable {
    public var id: String { url?.path ?? "leftover:\(bundleIdentifier ?? name)" }
    public var url: URL?
    public var bundleIdentifier: String?
    /// `CFBundleName`, else the bundle file name. Used for matching files.
    public var name: String
    public var displayName: String
    public var version: String?
    public var executableName: String?
    public var vendor: AppVendor
    public var store: AppStore
    /// Lives under /System/Applications or is SIP-protected: only its data can be removed ("reset").
    public var isSystem: Bool
    public var lastUsed: Date?
    public var privilegedHelpers: [String]
    public var isLeftover: Bool { url == nil }

    public var isAppStore: Bool { store == .appStore }

    /// Not opened for six months. Apps with no usage record never count as unused.
    public func isUnused(now: Date = Date()) -> Bool {
        guard let lastUsed, let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now) else { return false }
        return lastUsed < cutoff
    }

    public init(url: URL) {
        let info = NSDictionary(contentsOf: url.appending(path: "Contents/Info.plist")) as? [String: Any] ?? [:]
        self.url = url
        bundleIdentifier = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        name = (info["CFBundleName"] as? String)?.nilIfEmpty ?? url.deletingPathExtension().lastPathComponent
        displayName = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        version = (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String)
        executableName = info["CFBundleExecutable"] as? String
        vendor = AppVendor.forBundleID(bundleIdentifier)
        if bundleIdentifier?.hasSuffix("-setapp") == true {
            store = .setapp
        } else if FileManager.default.fileExists(atPath: url.appending(path: "Contents/_MASReceipt/receipt").path) {
            store = .appStore
        } else {
            store = .other
        }
        // Safari in /Applications is a symlink into /System/Cryptexes; judge by where the bundle really lives.
        isSystem = url.path.hasPrefix("/System/") || url.resolvingSymlinksInPath().path.hasPrefix("/System/")
            || Self.isRestricted(url.appending(path: "Contents/Info.plist"))
        lastUsed = Self.lastUsedDate(url)
        privilegedHelpers = ((info["SMPrivilegedExecutables"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    public init(leftoverBundleID: String, name: String) {
        url = nil
        bundleIdentifier = leftoverBundleID
        self.name = name
        displayName = name
        version = nil
        executableName = nil
        vendor = AppVendor.forBundleID(leftoverBundleID)
        store = .other
        isSystem = false
        lastUsed = nil
        privilegedHelpers = []
    }

    /// The SIP `restricted` file flag.
    static func isRestricted(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(SF_RESTRICTED) != 0
    }

    static func lastUsedDate(_ url: URL) -> Date? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Finds apps in /Applications (recursively, not inside other apps), ~/Applications and /System/Applications.
public enum ApplicationDiscovery {
    /// Virtualization bridges and web-app shims that look like apps but are not uninstallable on their own.
    static let ignoredBundleIDPrefixes = [
        "com.parallels.winapp", "com.parallels.ApplicationGroupBridge", "com.vmware.proxyApp",
        "com.codeweavers.CrossOverHelper", "com.google.Chrome.app.", "com.setapp.teaser",
    ]

    public static func installedApplications(home: URL = JunkPaths.current.home) -> [InstalledApplication] {
        let roots = [URL(fileURLWithPath: "/Applications"), home.appending(path: "Applications"), URL(fileURLWithPath: "/System/Applications")]
        var seen = Set<String>()
        return roots.flatMap { bundles(under: $0) }.compactMap { url -> InstalledApplication? in
            guard seen.insert(url.resolvingSymlinksInPath().path).inserted, isValidBundle(url) else { return nil }
            let app = InstalledApplication(url: url)
            if let id = app.bundleIdentifier, ignoredBundleIDPrefixes.contains(where: { id.hasPrefix($0) }) { return nil }
            return app
        }
    }

    /// Walks folders by hand and only skips dot-files: macOS ships Safari in /Applications as a symlink into
    /// its Cryptex with the hidden flag set, which `.skipsHiddenFiles` (and the enumerator) would drop.
    /// Nested apps and VM bundles are not entered.
    static func bundles(under root: URL, depth: Int = 0) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let entries = names.filter { !$0.hasPrefix(".") }.map { root.appending(path: $0) }
        return entries.flatMap { url -> [URL] in
            if url.pathExtension == "app" { return [url] }
            guard depth < 4, ![".pvm", ".vmwarevm", ".backupdb"].contains(where: url.lastPathComponent.hasSuffix),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true
            else { return [] }
            return bundles(under: url, depth: depth + 1)
        }
    }

    static func isValidBundle(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appending(path: "Contents/MacOS").path) && fm.fileExists(atPath: url.appending(path: "Contents/Info.plist").path)
    }

    /// Bundle ids of everything installed that can own files: apps plus plug-ins, preference panes and scripting additions.
    public static func installedBundleIdentifiers(apps: [InstalledApplication], home: URL) -> Set<String> {
        var ids = Set(apps.compactMap { $0.bundleIdentifier?.lowercased() })
        let pluginRoots = [
            "Library/PreferencePanes", "Library/ScriptingAdditions", "Library/Internet Plug-Ins", "Library/QuickLook",
            "Library/Spotlight", "Library/Services", "Library/Audio/Plug-Ins/Components", "Library/Audio/Plug-Ins/VST",
            "Library/Audio/Plug-Ins/VST3", "Library/Audio/Plug-Ins/HAL", "Library/Screen Savers", "Library/ColorPickers",
        ]
        for relative in pluginRoots {
            for root in [URL(fileURLWithPath: "/" + relative), home.appending(path: relative)] {
                for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    if let id = Bundle(url: url)?.bundleIdentifier { ids.insert(id.lowercased()) }
                }
            }
        }
        return ids
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
