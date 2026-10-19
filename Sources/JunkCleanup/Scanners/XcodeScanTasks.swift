import Foundation

private let xcodeBundleID = "com.apple.dt.Xcode"
private let simulatorBundleID = "com.apple.iphonesimulator"
let simctlPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

/// A directory-backed Xcode sub-category: each produces one subgroup of the "Xcode Junk" group.
private struct XcodeDirectoryTask: JunkScanTask {
    let identifier: String
    let title: String
    let group = JunkGroupID.xcodeJunk
    let collect: @Sendable (ScanContext) -> [JunkItem]

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let items = collect(context)
        return items.isEmpty ? [] : [JunkSubgroup(id: "xcode.\(identifier)", title: title, items: items)]
    }
}

private func xcodeItem(_ url: URL, name: String? = nil, detail: String? = nil, selected: Bool, _ context: ScanContext) -> JunkItem? {
    guard context.exists(url), !context.ignore.isIgnored(url), context.canRemove(url) else { return nil }
    let size = context.size(of: url)
    guard size > 0 else { return nil }
    return JunkItem(
        name: name ?? url.lastPathComponent,
        detail: detail,
        url: url,
        size: size,
        isAutoSelected: selected,
        action: .delete(url),
        quitBeforeCleaning: [xcodeBundleID]
    )
}

enum XcodeJunkScanTasks {
    static var all: [any JunkScanTask] {
        [
            XcodeDirectoryTask(identifier: "derivedData", title: "Derived Data", collect: derivedData),
            deviceSupport("iOS"), deviceSupport("macOS"), deviceSupport("tvOS"), deviceSupport("watchOS"),
            XcodeDirectoryTask(identifier: "documentationCache", title: "Xcode Documentation Cache", collect: documentationCache),
            XcodeDirectoryTask(identifier: "moduleCaches", title: "Module Caches", collect: moduleCaches),
            XcodeDirectoryTask(identifier: "archives", title: "Archives", collect: archives),
            XcodeDirectoryTask(identifier: "coreSimulatorCaches", title: "Xcode Caches") { context in
                [xcodeItem(context.paths.coreSimulator.appending(path: "Caches"), name: "CoreSimulator Caches", selected: false, context)].compactMap { $0 }
            },
            XcodeDirectoryTask(identifier: "deviceLogs", title: "iOS Device Logs") { context in
                [xcodeItem(context.paths.xcode.appending(path: "iOS Device Logs"), selected: true, context)].compactMap { $0 }
            },
            XcodeSimulatorsScanTask(),
            XcodeSimulatorRuntimesScanTask(),
        ]
    }

    /// Project build folders are named `<Project>-<hash>`; the shared index/symbol caches are kept unselected.
    private static func derivedData(_ context: ScanContext) -> [JunkItem] {
        context.children(of: context.paths.xcode.appending(path: "DerivedData"))
            .filter { $0.lastPathComponent != "ModuleCache" }
            .compactMap { url in
                let folder = url.lastPathComponent
                let name = folder.range(of: "-", options: .backwards).map { String(folder[..<$0.lowerBound]) } ?? folder
                let selected = !["ModuleCache.noindex", "SymbolCache.noindex"].contains(folder)
                return xcodeItem(url, name: name, selected: selected, context)
            }
            .sorted { $0.size > $1.size }
    }

    private static func deviceSupport(_ platform: String) -> XcodeDirectoryTask {
        XcodeDirectoryTask(identifier: "\(platform)DeviceSupport", title: "\(platform) Device Support") { context in
            context.children(of: context.paths.xcode.appending(path: "\(platform) DeviceSupport"))
                .compactMap { xcodeItem($0, selected: false, context) }
        }
    }

    private static func documentationCache(_ context: ScanContext) -> [JunkItem] {
        context.children(of: context.paths.xcode.appending(path: "DocumentationCache"))
            .flatMap { context.children(of: $0) }
            .compactMap { xcodeItem($0, name: "iOS \($0.lastPathComponent)", selected: false, context) }
    }

    private static func moduleCaches(_ context: ScanContext) -> [JunkItem] {
        var candidates: [(String, URL)] = [("com.apple.dt.xcode", context.paths.xcode.appending(path: "DerivedData/ModuleCache"))]
        if let darwin = context.paths.darwinUserCacheDirectory {
            candidates.insert(("org.llvm.clang", darwin.appending(path: "org.llvm.clang/ModuleCache")), at: 0)
            candidates.insert(("org.llvm.clang.\(NSUserName())", darwin.appending(path: "org.llvm.clang.\(NSUserName())/ModuleCache")), at: 1)
        }
        return candidates.compactMap { xcodeItem($1, name: $0, selected: false, context) }
    }

    /// `Archives/<date>/<name>.xcarchive`, titled from the archive's Info.plist.
    private static func archives(_ context: ScanContext) -> [JunkItem] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return context.children(of: context.paths.xcode.appending(path: "Archives"))
            .flatMap { context.children(of: $0) }
            .filter { $0.pathExtension == "xcarchive" }
            .compactMap { url -> JunkItem? in
                guard let info = NSDictionary(contentsOf: url.appending(path: "Info.plist")) else { return nil }
                let props = info["ApplicationProperties"] as? [String: Any]
                var title = info["Name"] as? String ?? url.deletingPathExtension().lastPathComponent
                if let version = props?["CFBundleShortVersionString"] as? String { title += " \(version)" }
                if let build = props?["CFBundleVersion"] as? String { title += " (\(build))" }
                let date = (info["CreationDate"] as? Date).map { formatter.string(from: $0) }
                return xcodeItem(url, name: title, detail: date, selected: false, context)
            }
    }
}

/// Simulator devices from `simctl list devices --json`, grouped by runtime. Unavailable devices are preselected.
struct XcodeSimulatorsScanTask: JunkScanTask {
    let identifier = "xcodeSimulators"
    let title = "Simulators"
    let group = JunkGroupID.xcodeJunk
    static let runtimePrefix = "com.apple.CoreSimulator.SimRuntime."

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        guard context.exists(context.paths.coreSimulator), Self.xcodeIsSetUp(context) else { return [] }
        let output = try ProcessRunner.run(simctlPath, ["list", "devices", "--json"])
        guard output.status == 0, !output.stdout.isEmpty,
              let json = try JSONSerialization.jsonObject(with: output.stdout) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]]
        else { return [] }

        var subgroups: [String: [JunkItem]] = [:]
        for (runtime, list) in devices {
            let isKnownRuntime = runtime.hasPrefix(Self.runtimePrefix)
            let groupTitle = isKnownRuntime ? Self.readableRuntime(runtime) : "Unused Simulators"
            if context.ignore.isIgnored(name: runtime) { continue }
            for device in list {
                guard let udid = device["udid"] as? String, let name = device["name"] as? String, device["state"] is String else { continue }
                let available = (device["isAvailable"] as? Bool) ?? (device["availability"] as? String == "(available)")
                let url = context.paths.coreSimulator.appending(path: "Devices/\(udid)")
                guard context.exists(url), !context.ignore.isIgnored(url) else { continue }
                let item = JunkItem(
                    id: "simulator.\(udid)",
                    name: name,
                    detail: available ? nil : "Unavailable",
                    url: url,
                    size: context.size(of: url),
                    isAutoSelected: !available,
                    action: .simctl(["delete", udid]),
                    quitBeforeCleaning: [xcodeBundleID, simulatorBundleID]
                )
                subgroups[groupTitle, default: []].append(item)
            }
        }
        return subgroups.keys.sorted().map { key in
            JunkSubgroup(id: "xcode.simulators.\(key)", title: "Simulators · \(key)", items: subgroups[key]!.sorted { $0.name < $1.name })
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-17-0` → `iOS 17.0`.
    static func readableRuntime(_ identifier: String) -> String {
        let trimmed = String(identifier.dropFirst(runtimePrefix.count))
        guard let firstDash = trimmed.firstIndex(of: "-") else { return trimmed }
        let platform = trimmed[..<firstDash]
        let version = trimmed[trimmed.index(after: firstDash)...].replacingOccurrences(of: "-", with: ".")
        return "\(platform) \(version)"
    }

    /// Xcode writes InstallCheckCache markers once its components are installed for this OS/Xcode build pair.
    /// Running simctl before that can trigger an install prompt, so skip until both markers exist.
    static func xcodeIsSetUp(_ context: ScanContext) -> Bool {
        guard let system = NSDictionary(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist")?["ProductBuildVersion"] as? String,
              let selected = try? ProcessRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 10), selected.status == 0
        else { return false }
        let developerDir = URL(fileURLWithPath: String(decoding: selected.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        guard let xcodeBuild = NSDictionary(contentsOf: developerDir.deletingLastPathComponent().appending(path: "version.plist"))?["ProductBuildVersion"] as? String else {
            return false
        }
        return ["CoreSim", "MobileDevice"].allSatisfy { name in
            context.exists(context.paths.temporaryDirectory.appending(path: "com.apple.dt.Xcode.InstallCheckCache_\(name)_\(system)_\(xcodeBuild)"))
        }
    }
}

/// Downloaded simulator runtimes that simctl reports as deletable.
struct XcodeSimulatorRuntimesScanTask: JunkScanTask {
    let identifier = "simulatorRuntimes"
    let title = "Simulator runtimes"
    let group = JunkGroupID.xcodeJunk
    var timeout: Duration { .seconds(300) }

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator")
        guard context.exists(root), !context.ignore.isIgnored(root),
              let selected = try? ProcessRunner.run("/bin/sh", ["-c", "/usr/bin/xcode-select -p"], timeout: 10), selected.status == 0,
              let output = try? ProcessRunner.run(simctlPath, ["runtime", "list", "-j"], timeout: 60), output.status == 0,
              let json = try? JSONSerialization.jsonObject(with: output.stdout) as? [String: [String: Any]]
        else { return [] }

        let items = json.values.compactMap { runtime -> JunkItem? in
            guard runtime["deletable"] as? Bool == true,
                  let identifier = runtime["identifier"] as? String,
                  let bundlePath = runtime["runtimeBundlePath"] as? String
            else { return nil }
            let url = URL(fileURLWithPath: bundlePath)
            guard context.exists(url), !context.ignore.isIgnored(url) else { return nil }
            return JunkItem(
                id: "runtime.\(identifier)",
                name: url.lastPathComponent,
                url: url,
                size: context.size(of: url),
                isAutoSelected: false,
                action: .simctl(["runtime", "delete", identifier]),
                quitBeforeCleaning: [xcodeBundleID, simulatorBundleID]
            )
        }
        return items.isEmpty ? [] : [JunkSubgroup(id: "xcode.runtimes", title: "Xcode Simulator Runtimes", items: items.sorted { $0.name < $1.name })]
    }
}
