import AppKit
import Foundation

/// Everything a scanner needs, shared read-only across concurrent scans.
public struct ScanContext: Sendable {
    public var paths: JunkPaths
    public var ignore: IgnoreSnapshot

    public init(paths: JunkPaths = .current, ignore: IgnoreSnapshot = IgnoreList.shared.snapshot()) {
        self.paths = paths
        self.ignore = ignore
    }

    /// Immediate children, skipping `.DS_Store` and ignored entries.
    public func children(of directory: URL, includeHidden: Bool = false) -> [URL] {
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: options
        )) ?? []
        return urls
            .filter { $0.lastPathComponent != ".DS_Store" && !ignore.isIgnored($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// We have no privileged helper, so only offer what the current user can actually remove.
    public func canRemove(_ url: URL) -> Bool {
        FileManager.default.isDeletableFile(atPath: url.path)
    }

    public func size(of url: URL) -> Int64 { FileSizer.allocatedSize(of: url) }
}

/// Bundle id → app name, falling back to the raw identifier.
enum AppNames {
    static func displayName(forBundleIdentifier identifier: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return identifier }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Apps in /Applications and ~/Applications (one level, plus Utilities).
enum InstalledApps {
    struct App: Sendable {
        var url: URL
        var bundleIdentifier: String?
        var name: String
        var executableURL: URL?
    }

    static func all(home: URL) -> [App] {
        let roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appending(path: "Applications"),
        ]
        return roots.flatMap { root -> [App] in
            let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            return urls.filter { $0.pathExtension == "app" }.map { url in
                let bundle = Bundle(url: url)
                return App(
                    url: url,
                    bundleIdentifier: bundle?.bundleIdentifier,
                    name: url.deletingPathExtension().lastPathComponent,
                    executableURL: bundle?.executableURL
                )
            }
        }
    }
}
