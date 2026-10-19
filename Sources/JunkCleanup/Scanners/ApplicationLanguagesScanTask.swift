import Foundation

/// Unused `.lproj` localizations inside third-party apps, grouped by language.
struct ApplicationLanguagesScanTask: JunkScanTask {
    let identifier = "applicationLanguages"
    let title = "Language files"
    let group = JunkGroupID.applicationLanguages

    /// Language codes kept regardless of the user's settings.
    private static let alwaysKept: Set<String> = ["en", "english", "base", "default", "empty", "."]

    func scan(_ context: ScanContext) async throws -> [JunkSubgroup] {
        let kept = Self.keptLanguages()
        var byLanguage: [String: [JunkItem]] = [:]
        for app in InstalledApps.all(home: context.paths.home) {
            try Task.checkCancellation()
            guard context.canRemove(app.url), !context.ignore.isIgnored(app.url),
                  !(app.bundleIdentifier.map(context.ignore.isIgnored(name:)) ?? false)
            else { continue }
            for (language, folders) in Self.removableLocalizations(in: app.url, kept: kept) {
                for folder in folders where context.canRemove(folder) {
                    let size = context.size(of: folder)
                    guard size > 0 else { continue }
                    byLanguage[language, default: []].append(
                        JunkItem(name: app.name, detail: folder.path.replacingOccurrences(of: app.url.path, with: app.name + ".app"), url: folder, size: size, isAutoSelected: true, action: .delete(folder), quitBeforeCleaning: app.bundleIdentifier.map { [$0] } ?? [])
                    )
                }
            }
        }
        return byLanguage.keys.sorted().map { code in
            let title = Locale.current.localizedString(forLanguageCode: code) ?? code
            return JunkSubgroup(id: "languages.\(code)", title: title, items: byLanguage[code]!.sorted { $0.size > $1.size })
        }
    }

    /// The user's preferred languages (base codes) plus the always-kept set.
    static func keptLanguages(preferred: [String] = Locale.preferredLanguages) -> Set<String> {
        alwaysKept.union(preferred.map { canonical($0) })
    }

    static func isKept(_ code: String, kept: Set<String>) -> Bool {
        let lower = code.lowercased()
        return kept.contains(lower) || lower.hasPrefix("en-") || lower.hasPrefix("en_")
    }

    /// `English.lproj` → `en`, `pt-BR` → `pt`, with two legacy fixups.
    static func canonical(_ name: String) -> String {
        let identifier = Locale.canonicalLanguageIdentifier(from: name)
        var base = identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? name.lowercased()
        if base == "ua" { base = "uk" }
        if base == "jp" { base = "ja" }
        return base
    }

    /// Walks every `Resources` folder in the bundle (main app, frameworks, plug-ins) and returns removable lproj folders by language.
    static func removableLocalizations(in bundle: URL, kept: Set<String>) -> [String: [URL]] {
        var result: [String: [URL]] = [:]
        let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if url.pathExtension == "lproj" {
                enumerator?.skipDescendants()
                continue
            }
            guard url.lastPathComponent.lowercased() == "resources" else { continue }
            for (language, folder) in removable(inResources: url, kept: kept) {
                result[language, default: []].append(folder)
            }
        }
        return result
    }

    /// Only touches a Resources folder that will still contain at least one kept language afterwards.
    static func removable(inResources resources: URL, kept: Set<String>) -> [(String, URL)] {
        let lprojs = ((try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "lproj" }
        let keptCount = lprojs.filter { isKept(canonical($0.deletingPathExtension().lastPathComponent), kept: kept) }.count
        guard keptCount > 0 else { return [] }

        let sealed = CodeResources(resourcesFolder: resources)
        return lprojs.compactMap { folder in
            let code = canonical(folder.deletingPathExtension().lastPathComponent)
            guard !isKept(code, kept: kept), containsOnlyStrings(folder), !sealed.hasRequiredFile(inside: folder) else { return nil }
            return (code, folder)
        }
    }

    /// Nibs, images or nested bundles inside an lproj make it unsafe to remove.
    static func containsOnlyStrings(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        var sawFile = false
        while let url = enumerator.nextObject() as? URL {
            guard ["strings", "stringsdict"].contains(url.pathExtension) else { return false }
            sawFile = true
        }
        return sawFile
    }
}

/// Read-only helpers for inspecting what a scanner would do to a single bundle.
public enum JunkCleanupInspection {
    public static func removableLocalizations(in bundle: URL) -> [String: [URL]] {
        ApplicationLanguagesScanTask.removableLocalizations(in: bundle, kept: ApplicationLanguagesScanTask.keptLanguages())
    }
}

/// Files sealed as non-optional by a bundle's code signature; removing one breaks the signature.
struct CodeResources {
    private var required: Set<String> = []
    private var root: URL

    /// For `X/Resources/fr.lproj`, the seal lives at `X/_CodeSignature/CodeResources` with keys relative to `X`.
    init(resourcesFolder: URL) {
        root = resourcesFolder.deletingLastPathComponent()
        guard let plist = NSDictionary(contentsOf: root.appending(path: "_CodeSignature/CodeResources")) as? [String: Any] else { return }
        for key in ["files", "files2"] {
            for (path, value) in (plist[key] as? [String: Any]) ?? [:] {
                let optional = (value as? [String: Any])?["optional"] as? Bool ?? false
                if !optional { required.insert(path) }
            }
        }
    }

    func hasRequiredFile(inside folder: URL) -> Bool {
        let prefix = String(folder.path.dropFirst(root.path.count + 1)) + "/"
        return required.contains { $0.hasPrefix(prefix) }
    }
}
