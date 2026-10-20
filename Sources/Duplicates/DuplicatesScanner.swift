import Foundation
import JunkCleanup

public struct DuplicatesScanResult: Sendable {
    public var duplicates: [DuplicateGroup]
    public var similarImages: [SimilarImageGroup]
    public var filesScanned: Int
}

public enum DuplicatesScanPhase: Sendable {
    case enumerating(found: Int)
    case hashing(done: Int, total: Int)
    case comparingImages(done: Int, total: Int)
}

/// Finds duplicate files and similar photos under one folder.
public final class DuplicatesScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private let hasFullDiskAccess: Bool

    public init(hasFullDiskAccess: Bool = Permissions.hasFullDiskAccess) {
        self.hasFullDiskAccess = hasFullDiskAccess
    }

    public func cancel() { lock.withLock { cancelled = true } }
    private var isCancelled: Bool { lock.withLock { cancelled } }

    public func scan(_ root: URL, progress: @escaping @Sendable (DuplicatesScanPhase) -> Void = { _ in }) async throws -> DuplicatesScanResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let rules = ScanRules(root: root, hasFullDiskAccess: self.hasFullDiskAccess)
                let files = FileEnumerator.files(under: root.standardizedFileURL, rules: rules, isCancelled: { self.isCancelled }) {
                    progress(.enumerating(found: $0))
                }
                let cancelled: @Sendable () -> Bool = { [unowned self] in self.isCancelled }
                let duplicates = DuplicateFinder.groups(in: files, isCancelled: cancelled) { progress(.hashing(done: $0, total: $1)) }
                let similar = SimilarImages.groups(in: files, isCancelled: cancelled) { progress(.comparingImages(done: $0, total: $1)) }
                if self.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: DuplicatesScanResult(duplicates: duplicates, similarImages: similar, filesScanned: files.count))
                }
            }
        }
    }

    /// Moves the given files to the Trash; returns the paths that failed with their error.
    public static func trash(_ urls: [URL]) -> [String: String] {
        var failures: [String: String] = [:]
        for url in urls {
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) } catch { failures[url.path] = error.localizedDescription }
        }
        return failures
    }
}
