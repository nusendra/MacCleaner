import Foundation

/// Top-level ~/Library/Preferences/*.plist files that no longer parse.
struct BrokenPreferencesScanTask: JunkScanTask {
    let identifier = "brokenPreferences"
    let title = "Broken preferences"
    let group = JunkGroupID.brokenPreferences

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let items = context.children(of: context.paths.userPreferences).compactMap { url -> JunkItem? in
            guard Self.isBroken(url), context.canRemove(url) else { return nil }
            return JunkItem(
                name: url.deletingPathExtension().lastPathComponent,
                url: url,
                size: context.size(of: url),
                isAutoSelected: true,
                action: .removePreference(url)
            )
        }
        return items.isEmpty ? [] : [JunkSubgroup(id: "brokenPreferences", title: "Preference Files", items: items)]
    }

    /// Non-empty, unlocked plist that fails to parse or is not a valid property list. Empty files are not broken.
    static func isBroken(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard url.pathExtension.lowercased() == "plist", !name.hasPrefix("."), !url.path.contains(".lockfile"),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isUserImmutableKey, .isRegularFileKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0, values.isUserImmutable != true,
              let data = try? Data(contentsOf: url)
        else { return false }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) == nil
    }
}

/// Launch agents whose program no longer exists. Only the user's own agents are removable without admin rights.
struct BrokenLaunchAgentsScanTask: JunkScanTask {
    let identifier = "brokenStartupItems"
    let title = "Broken login items"
    let group = JunkGroupID.brokenStartupItems

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let folders = [
            context.paths.library.appending(path: "LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchAgents"),
            URL(fileURLWithPath: "/Library/LaunchDaemons"),
        ]
        let helperNames = Self.privilegedHelperNames(home: context.paths.home)
        let items = folders.flatMap { context.children(of: $0) }.compactMap { url -> JunkItem? in
            guard url.pathExtension == "plist", context.canRemove(url), FileManager.default.isReadableFile(atPath: url.path) else { return nil }
            let config = NSDictionary(contentsOf: url) as? [String: Any]
            guard Self.isBroken(config, helperNames: helperNames) else { return nil }
            return JunkItem(
                name: url.deletingPathExtension().lastPathComponent,
                detail: (config?["Program"] as? String) ?? ((config?["ProgramArguments"] as? [String])?.first),
                url: url,
                size: context.size(of: url),
                isAutoSelected: true,
                action: .removeLaunchAgent(url)
            )
        }
        return items.isEmpty ? [] : [JunkSubgroup(id: "launchAgents", title: "Launch Agents", items: items)]
    }

    static func isBroken(_ config: [String: Any]?, helperNames: Set<String>) -> Bool {
        guard let config else { return true }
        guard var program = (config["Program"] as? String) ?? (config["ProgramArguments"] as? [String])?.first else { return true }
        if let workingDirectory = config["WorkingDirectory"] as? String, !program.hasPrefix("/") {
            program = (workingDirectory as NSString).appendingPathComponent(program)
        }
        program = ((program as NSString).expandingTildeInPath as NSString).standardizingPath
        // A path we cannot see into (e.g. a root-only folder) gets the benefit of the doubt.
        let parent = (program as NSString).deletingLastPathComponent
        if !FileManager.default.isReadableFile(atPath: parent) { return false }
        if FileManager.default.fileExists(atPath: program) { return false }
        // Privileged helpers are installed lazily by their app; a missing one is not broken.
        return !helperNames.contains((program as NSString).lastPathComponent)
    }

    /// Names of SMJobBless helpers declared by installed apps.
    static func privilegedHelperNames(home: URL) -> Set<String> {
        Set(InstalledApps.all(home: home).flatMap { app -> [String] in
            let info = NSDictionary(contentsOf: app.url.appending(path: "Contents/Info.plist"))
            return ((info?["SMPrivilegedExecutables"] as? [String: Any]) ?? [:]).keys.map { $0 }
        })
    }
}

/// Disk images left by deleting a user while keeping their home folder.
struct DeletedUsersScanTask: JunkScanTask {
    let identifier = "deletedUsers"
    let title = "Deleted users"
    let group = JunkGroupID.deletedUsers

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let items = context.children(of: URL(fileURLWithPath: "/Users/Deleted Users"))
            .filter { $0.pathExtension == "dmg" && context.canRemove($0) }
            .map { JunkItem(name: $0.deletingPathExtension().lastPathComponent, url: $0, size: context.size(of: $0), isAutoSelected: false, action: .delete($0)) }
        return items.isEmpty ? [] : [JunkSubgroup(id: "deletedUsers", title: "Deleted User Images", items: items)]
    }
}

/// iPhone/iPad backups grouped by device; every backup except the newest per device is preselected.
struct MobileBackupsScanTask: JunkScanTask {
    let identifier = "mobileBackups"
    let title = "iOS backups"
    let group = JunkGroupID.mobileBackups

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let root = context.paths.applicationSupport.appending(path: "MobileSync/Backup")
        var byDevice: [String: [(url: URL, date: Date)]] = [:]
        var broken: [URL] = []
        for backup in context.children(of: root) where context.canRemove(backup) {
            let info = NSDictionary(contentsOf: backup.appending(path: "Info.plist"))
            guard let deviceName = info?["Device Name"] as? String else {
                broken.append(backup)
                continue
            }
            let product = info?["Product Type"] as? String
            let device = product.map { "\(deviceName) (\($0))" } ?? deviceName
            if context.ignore.isIgnored(name: device) { continue }
            let status = NSDictionary(contentsOf: backup.appending(path: "Status.plist"))
            let date = (status?["Date"] as? Date) ?? (info?["Last Backup Date"] as? Date) ?? .distantPast
            byDevice[device, default: []].append((backup, date))
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        var subgroups = byDevice.keys.sorted().map { device in
            let backups = byDevice[device]!.sorted { $0.date > $1.date }
            let items = backups.enumerated().map { index, backup in
                JunkItem(
                    name: formatter.string(from: backup.date),
                    detail: index == 0 ? "Latest backup" : nil,
                    url: backup.url,
                    size: context.size(of: backup.url),
                    isAutoSelected: index != 0,
                    action: .delete(backup.url)
                )
            }
            return JunkSubgroup(id: "backups.\(device)", title: device, items: items)
        }
        if !broken.isEmpty && !context.ignore.isIgnored(name: "Broken Backups") {
            let items = broken.map { JunkItem(name: $0.lastPathComponent, detail: "Incomplete backup", url: $0, size: context.size(of: $0), isAutoSelected: true, action: .delete($0)) }
            subgroups.append(JunkSubgroup(id: "backups.broken", title: "Broken Backups", items: items))
        }
        return subgroups
    }
}
