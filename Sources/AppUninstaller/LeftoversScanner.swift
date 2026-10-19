import AppKit
import Foundation
import JunkCleanup

/// Finds bundle ids that still have files on disk although no installed app owns them.
public struct LeftoversScanner: Sendable {
    public var paths: JunkPaths
    public var ignore: IgnoreSnapshot

    /// Identifiers owned by the OS or system services rather than an uninstallable app.
    /// OS identifiers and third-party frameworks embedded in many apps; neither is an app that can be "left over".
    static let systemPrefixes = [
        "com.apple.", "group.com.apple.", "systemgroup.com.apple.", "org.cups.", "com.openssh.", "org.openssh.",
        "org.sparkle-project.", "com.qtproject", "com.segment.", "com.crashlytics", "io.sentry", "com.microsoft.appcenter",
    ]

    /// Components that mark files a vendor shares between its apps (`com.microsoft.shared`, `us.zoom.updater.config`).
    static let vendorSharedWords: Set<String> = [
        "shared", "common", "autoupdate", "updater", "update", "config", "errorreporting", "crashreporter", "helper", "agent", "fba",
    ]

    /// Trailing components that name a helper of an app (`com.foo.app.helper` belongs to `com.foo.app`).
    static let helperSuffixes: Set<String> = [
        "updater", "helper", "agent", "service", "launcher", "preferences", "preference", "accounts", "settings",
        "config", "mail", "calendars", "contacts", "keychains", "extension", "widget", "menu", "fileprovider",
        "findersync", "macos", "mac", "ios",
    ]

    public init(paths: JunkPaths = .current, ignore: IgnoreSnapshot = IgnoreList.shared.snapshot()) {
        self.paths = paths
        self.ignore = ignore
    }

    public struct Candidate: Hashable, Sendable {
        public var bundleID: String
        public var name: String
        public var sourcePath: String
    }

    /// Candidates from sandbox containers (their app is gone) and reverse-DNS preference files.
    public func candidates(installedIDs: Set<String>, isKnownToLaunchServices: (String) -> Bool = Self.launchServicesKnows) -> [Candidate] {
        var result: [Candidate] = []
        var seen = Set<String>()
        func add(_ candidate: Candidate?) {
            guard let candidate, seen.insert(candidate.bundleID.lowercased()).inserted else { return }
            result.append(candidate)
        }

        for container in (try? FileManager.default.contentsOfDirectory(at: paths.containers, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            if let bundle = Self.containerApplicationPath(container), FileManager.default.fileExists(atPath: bundle) { continue }
            let id = Self.containerIdentifier(container) ?? container.lastPathComponent
            add(candidate(id: id, url: container, installedIDs: installedIDs, isKnownToLaunchServices: isKnownToLaunchServices))
        }
        for pref in (try? FileManager.default.contentsOfDirectory(at: paths.userPreferences, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        where ["plist", "xml"].contains(pref.pathExtension.lowercased()) {
            // Only the file extension is stripped; bundle ids themselves contain dots.
            add(candidate(id: pref.deletingPathExtension().lastPathComponent, url: pref, installedIDs: installedIDs, isKnownToLaunchServices: isKnownToLaunchServices))
        }
        return Self.mergingHelpers(result)
    }

    /// `com.foo.app.private` and `com.foo.app.Extension` fold into `com.foo.app` when that is also a leftover;
    /// the resource scan of `com.foo.app` already finds their files.
    static func mergingHelpers(_ candidates: [Candidate]) -> [Candidate] {
        let ids = candidates.map { $0.bundleID.lowercased() }
        return candidates.filter { candidate in
            let id = candidate.bundleID.lowercased()
            return !ids.contains { other in other != id && id.hasPrefix(other + ".") }
        }
    }

    func candidate(id: String, url: URL, installedIDs: Set<String>, isKnownToLaunchServices: (String) -> Bool) -> Candidate? {
        let lower = id.lowercased()
        guard lower.contains("."), !Self.systemPrefixes.contains(where: lower.hasPrefix),
              !ignore.isIgnored(url), !ignore.isIgnored(name: id), !isKnownToLaunchServices(id)
        else { return nil }
        let variants = Self.variants(of: lower)
        if variants.contains(where: { variant in Self.systemPrefixes.contains(where: variant.hasPrefix) }) { return nil }
        if variants.contains(where: { variant in Self.belongsToInstalled(variant, installedIDs: installedIDs) }) { return nil }
        if Self.isVendorSharedFile(lower, installedIDs: installedIDs) { return nil }

        let shortName = (id as NSString).pathExtension.isEmpty ? id : (id as NSString).pathExtension
        let installedByName = [shortName].contains { name in
            ["/Applications/\(name).app", paths.home.appending(path: "Applications/\(name).app").path].contains(where: FileManager.default.fileExists)
        }
        guard !installedByName else { return nil }
        return Candidate(bundleID: id, name: Self.displayName(for: id), sourcePath: url.path)
    }

    /// `org.gimp.gimp-2.10` → `gimp-2.10`, `3t.mongochef.enterprise` → `mongochef.enterprise`: drop the vendor domain.
    static func displayName(for id: String) -> String {
        let parts = id.split(separator: ".").map(String.init)
        return parts.count > 2 ? parts.dropFirst(2).joined(separator: ".") : (parts.last ?? id)
    }

    /// Same vendor domain as an installed app, and named like a component the vendor shares between its apps.
    static func isVendorSharedFile(_ id: String, installedIDs: Set<String>) -> Bool {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return false }
        let vendor = parts.prefix(2).joined(separator: ".") + "."
        guard installedIDs.contains(where: { $0.hasPrefix(vendor) }) else { return false }
        return parts.dropFirst(2).contains { component in
            vendorSharedWords.contains { component.hasPrefix($0) }
        }
    }

    /// The id plus forms with a Team ID prefix, `group.`/`maccatalyst.` prefix or a helper suffix removed.
    static func variants(of id: String) -> [String] {
        var result = [id]
        var components = id.split(separator: ".").map(String.init)
        if let first = components.first, first.count == 10, first.allSatisfy({ $0.isLetter || $0.isNumber }), components.count > 1 {
            components.removeFirst()
            result.append(components.joined(separator: "."))
        }
        for prefix in ["group.", "systemgroup.", "maccatalyst."] where id.hasPrefix(prefix) {
            result.append(String(id.dropFirst(prefix.count)))
        }
        for variant in result {
            let parts = variant.split(separator: ".").map(String.init)
            guard parts.count > 3, let last = parts.last else { continue }
            let isHelper = helperSuffixes.contains(last)
                || (last.hasSuffix("extension") && last.count > "extension".count + 3)
                || (last.hasSuffix("service") && last.count > "service".count + 3)
            if isHelper { result.append(parts.dropLast().joined(separator: ".")) }
        }
        return result
    }

    /// Prefix match in either direction after normalizing case, spaces and dashes; or the same product family
    /// once version numbers are ignored (`net.telestream.screenflow.globallibrary` belongs to `net.telestream.screenflow10`).
    static func belongsToInstalled(_ variant: String, installedIDs: Set<String>) -> Bool {
        let normalize: (String) -> String = { $0.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "") }
        let candidate = normalize(variant)
        let candidateFamily = family(of: variant)
        return installedIDs.contains { installed in
            let id = normalize(installed)
            if candidate.hasPrefix(id) || id.hasPrefix(candidate) { return true }
            return candidateFamily.count >= 3 && family(of: installed).starts(with: candidateFamily.prefix(3))
        }
    }

    /// Lowercased components with version digits and separators trimmed off the end of each, e.g. `screenflow10` → `screenflow`.
    static func family(of id: String) -> [String] {
        id.lowercased().split(separator: ".").map { component in
            String(component).trimmingCharacters(in: CharacterSet.decimalDigits.union(CharacterSet(charactersIn: "-_ ")))
        }.filter { !$0.isEmpty }
    }

    /// The bundle id recorded for a container (iOS apps and some extensions use UUID-named folders).
    static func containerIdentifier(_ container: URL) -> String? {
        let plist = NSDictionary(contentsOf: container.appending(path: ".com.apple.containermanagerd.metadata.plist")) as? [String: Any]
        return (plist?["MCMMetadataIdentifier"] as? String)?.nilIfEmpty
    }

    /// The app bundle a sandbox container was created for, from the container metadata.
    static func containerApplicationPath(_ container: URL) -> String? {
        for name in [".com.apple.containermanagerd.metadata.plist", "Container.plist"] {
            guard let plist = NSDictionary(contentsOf: container.appending(path: name)) as? [String: Any],
                  let info = plist["MCMMetadataInfo"] as? [String: Any] ?? Optional(plist),
                  let validation = info["SandboxProfileDataValidationInfo"] as? [String: Any],
                  let parameters = validation["SandboxProfileDataValidationParametersKey"] as? [String: Any],
                  let bundle = parameters["application_bundle"] as? String
            else { continue }
            return bundle
        }
        return nil
    }

    public static func launchServicesKnows(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
