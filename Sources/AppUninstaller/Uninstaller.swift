import Darwin
import Foundation
import JunkCleanup

public enum UninstallError: LocalizedError {
    case commandFailed(String)
    case notRemovable(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message), .notRemovable(let message): message
        }
    }
}

public struct UninstallResult: Identifiable, Sendable {
    public var resource: AppResource
    public var error: String?
    public var id: String { resource.id }
    public var succeeded: Bool { error == nil }
}

/// Removes resources in a safe order: stop launchd jobs, clean preferences and the Dock, then move files to the Trash.
public struct Uninstaller: Sendable {
    public init() {}

    public func remove(_ resources: [AppResource], progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async -> [UninstallResult] {
        let ordered = resources.sorted { Self.priority($0.removal) < Self.priority($1.removal) }
        var results: [UninstallResult] = []
        var dockPaths = Set<String>()
        var touchedPreferences = false

        for (index, resource) in ordered.enumerated() {
            progress(index, ordered.count)
            if Task.isCancelled {
                results.append(UninstallResult(resource: resource, error: "Stopped."))
                continue
            }
            do {
                guard resource.isRemovable else { throw UninstallError.notRemovable(resource.note ?? "This item cannot be removed.") }
                switch resource.removal {
                case .dockTile(let path):
                    dockPaths.insert(path)
                case .preferences:
                    touchedPreferences = true
                    try Self.perform(resource.removal)
                default:
                    try Self.perform(resource.removal)
                }
                results.append(UninstallResult(resource: resource, error: nil))
            } catch {
                results.append(UninstallResult(resource: resource, error: error.localizedDescription))
            }
        }

        if !dockPaths.isEmpty {
            do {
                try DockTiles.remove(appPaths: dockPaths)
            } catch {
                results = results.map { result in
                    guard case .dockTile = result.resource.removal else { return result }
                    return UninstallResult(resource: result.resource, error: error.localizedDescription)
                }
            }
        }
        // Make cfprefsd drop cached copies of the deleted domains (once per batch, it relaunches on demand).
        if touchedPreferences {
            _ = try? ProcessRunner.run("/usr/bin/killall", ["-u", NSUserName(), "cfprefsd"], timeout: 10)
        }
        return results
    }

    /// Jobs and helpers first so nothing recreates files while they are being removed; the app bundle last.
    static func priority(_ removal: ResourceRemoval) -> Int {
        switch removal {
        case .launchAgent, .loginItemHelper: 0
        case .preferences: 1
        case .dockTile: 2
        case .trash(let url): url.pathExtension == "app" ? 4 : 3
        }
    }

    static func perform(_ removal: ResourceRemoval) throws {
        switch removal {
        case .trash(let url):
            try trash(url)
        case .preferences(let url):
            _ = try? ProcessRunner.run("/usr/bin/defaults", ["delete", url.deletingPathExtension().path], timeout: 15)
            try trash(url)
        case .launchAgent(let url, let label):
            let domain = url.path.hasPrefix(NSHomeDirectory()) ? "gui/\(getuid())" : "system"
            if let label {
                _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", "\(domain)/\(label)"], timeout: 15)
            } else {
                _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", domain, url.path], timeout: 15)
            }
            try trash(url)
        case .loginItemHelper(let label):
            let output = try ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], timeout: 15)
            // 3 = "No such process": already unloaded, which is what we want.
            guard output.status == 0 || output.status == 3 else {
                throw UninstallError.commandFailed("Could not unload login item \(label).")
            }
        case .dockTile(let path):
            try DockTiles.remove(appPaths: [path])
        }
    }

    /// Uninstalled items go to the Trash so a mistake can be undone from Finder.
    static func trash(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else { return }
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
