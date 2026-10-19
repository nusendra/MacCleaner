import Darwin
import Foundation

public struct JunkCleanItemResult: Sendable, Identifiable {
    public var item: JunkItem
    public var error: String?

    public var id: String { item.id }
    public var succeeded: Bool { error == nil }
}

public struct JunkCleanReport: Sendable {
    public enum Outcome: Sendable { case success, partialSuccess, empty, failure }

    public var results: [JunkCleanItemResult]

    public var removedSize: Int64 { results.filter(\.succeeded).reduce(0) { $0 + $1.item.size } }
    public var failures: [JunkCleanItemResult] { results.filter { !$0.succeeded } }

    public var outcome: Outcome {
        if results.isEmpty { return .empty }
        let failed = failures.count
        if failed == 0 { return .success }
        return failed == results.count ? .failure : .partialSuccess
    }
}

public enum JunkCleanerError: LocalizedError {
    case commandFailed(String)
    case versionNotFound

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        case .versionNotFound: "This version no longer exists."
        }
    }
}

/// Removes items one at a time so a failure affects only that item.
public struct JunkCleaner: Sendable {
    public init() {}

    public func clean(
        _ items: [JunkItem],
        progress: @escaping @Sendable (_ done: Int, _ total: Int, _ current: JunkItem) -> Void = { _, _, _ in }
    ) async -> JunkCleanReport {
        var results: [JunkCleanItemResult] = []
        for (index, item) in items.enumerated() {
            if Task.isCancelled {
                results.append(JunkCleanItemResult(item: item, error: "Cleaning was stopped."))
                continue
            }
            progress(index, items.count, item)
            do {
                try Self.perform(item.action)
                results.append(JunkCleanItemResult(item: item, error: nil))
            } catch {
                results.append(JunkCleanItemResult(item: item, error: error.localizedDescription))
            }
        }
        return JunkCleanReport(results: results)
    }

    static func perform(_ action: RemovalAction) throws {
        let fileManager = FileManager.default
        switch action {
        case .delete(let url):
            try removeIfPresent(url)

        case .truncateOrDelete(let url):
            guard fileManager.fileExists(atPath: url.path) else { return }
            if ["log", "txt"].contains(url.pathExtension.lowercased()) {
                guard truncate(url.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else {
                try removeIfPresent(url)
            }

        case .removePreference(let url):
            // Ask cfprefsd to forget the domain first so it does not write the cached copy back.
            _ = try? ProcessRunner.run("/usr/bin/defaults", ["delete", url.deletingPathExtension().path], timeout: 15)
            try removeIfPresent(url)

        case .removeLaunchAgent(let url):
            _ = try? ProcessRunner.run("/bin/launchctl", ["bootout", "gui/\(getuid())", url.path], timeout: 15)
            try removeIfPresent(url)

        case .removeFileVersion(let document, let date):
            guard let version = NSFileVersion.otherVersionsOfItem(at: document)?.first(where: { $0.modificationDate == date }) else {
                throw JunkCleanerError.versionNotFound
            }
            try version.remove()

        case .simctl(let arguments):
            let output = try ProcessRunner.run(simctlPath, arguments, timeout: 300)
            guard output.status == 0 else {
                throw JunkCleanerError.commandFailed(output.stderr.isEmpty ? "simctl exited with status \(output.status)" : output.stderr)
            }

        case .thinBinary(let url, let architecture):
            try thin(url, keeping: architecture)
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) || (try? url.checkResourceIsReachable()) == true else { return }
        // Clear the "locked" flag that would otherwise make removal fail.
        try? fileManager.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try fileManager.removeItem(at: url)
    }

    /// Rewrites the binary keeping only one slice (as a single-slice fat file, like `lipo -extract`).
    /// Each slice carries its own code signature, so the kept slice stays validly signed.
    /// The temporary file lives outside the bundle (same volume): a leftover inside it would break the bundle's seal.
    private static func thin(_ url: URL, keeping architecture: String) throws {
        let fileManager = FileManager.default
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let temp = scratch.appending(path: url.lastPathComponent)
        let output = try ProcessRunner.run("/usr/bin/lipo", [url.path, "-extract", architecture, "-output", temp.path], timeout: 60)
        guard output.status == 0 else {
            throw JunkCleanerError.commandFailed(output.stderr.isEmpty ? "lipo failed" : output.stderr)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }
}
