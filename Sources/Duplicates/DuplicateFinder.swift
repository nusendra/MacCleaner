import CryptoKit
import Foundation

public struct DuplicateGroup: Identifiable, Sendable {
    public var files: [ScannedFile]
    /// Indices into `files` that Smart Select marks for removal (every copy but the one to keep).
    public var autoselected: Set<Int>
    public var kind: DuplicateKind
    public var size: Int64 { files.first?.size ?? 0 }
    public var wastedSize: Int64 { size * Int64(max(files.count - 1, 0)) }
    public var id: String { files.map(\.path).sorted().first ?? "" }
    public var title: String { files[keptIndex].name }
    public var keptIndex: Int { files.indices.first { !autoselected.contains($0) } ?? 0 }
}

public enum DuplicateFinder {
    /// Files up to this size are hashed whole; larger ones from four 1 MiB samples, as in CleanMyMac.
    static let sampleChunk = 1 << 20
    static let sampleCount = 4

    /// Groups identical files: same size, then same sampled SHA-1, then (for sampled files) the same full content.
    public static func groups(in files: [ScannedFile], isCancelled: @escaping @Sendable () -> Bool = { false },
                              progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) -> [DuplicateGroup] {
        // Hard links share their data, so keep one path per inode.
        var seenInodes = Set<ScannedFile.FileID>()
        let unique = files.filter { seenInodes.insert($0.fileID).inserted }
        let candidates = Dictionary(grouping: unique, by: \.size).values.filter { $0.count > 1 }.flatMap { $0 }

        let hashes = ConcurrentMap.map(candidates, isCancelled: isCancelled, progress: progress) { file in
            file.isBundle ? bundleHash(file.url) : sampledHash(file)
        }
        var bySignature: [String: [ScannedFile]] = [:]
        for (file, hash) in zip(candidates, hashes) {
            guard let hash else { continue }
            bySignature["\(file.size)-\(hash)", default: []].append(file)
        }

        var groups: [DuplicateGroup] = []
        for files in bySignature.values where files.count > 1 {
            // Samples can collide for large files that differ elsewhere: confirm with a full hash.
            let confirmed: [[ScannedFile]]
            if !files[0].isBundle, files[0].size > Int64(sampleChunk * sampleCount) {
                confirmed = Dictionary(grouping: files) { fullHash($0.url) ?? UUID().uuidString }.values.filter { $0.count > 1 }.map { $0 }
            } else {
                confirmed = [files]
            }
            for set in confirmed {
                let ordered = DuplicatePrioritizer.sortedForKeeping(set)
                groups.append(DuplicateGroup(files: ordered, autoselected: Set(ordered.indices.dropFirst()), kind: DuplicateKind.of(ordered[0].url)))
            }
        }
        return groups.sorted { $0.wastedSize > $1.wastedSize }
    }

    static func sampledHash(_ file: ScannedFile) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file.url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        let size = UInt64(file.size)
        let chunk = UInt64(sampleChunk)
        if UInt64(sampleCount) * chunk < size {
            let step = size / UInt64(sampleCount)
            for i in 0..<UInt64(sampleCount) {
                guard (try? handle.seek(toOffset: i * step)) != nil, let data = try? handle.read(upToCount: sampleChunk) else { return nil }
                hasher.update(data: data)
            }
        } else {
            guard let data = try? handle.readToEnd() else { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fullHash(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let data = try? handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A bundle's identity: SHA-1 over its files' relative paths and contents, in path order.
    static func bundleHash(_ url: URL) -> String? {
        var files: [(String, URL)] = []
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files.append((String(file.path.dropFirst(url.path.count)), file))
            }
        }
        var hasher = Insecure.SHA1()
        for (relative, file) in files.sorted(by: { $0.0 < $1.0 }) {
            hasher.update(data: Data(relative.utf8))
            guard let hash = sampledHash(ScannedFile(url: file, size: Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0),
                                                       modified: nil, created: nil, isBundle: false, fileID: .init(device: 0, inode: 0)))
            else { return nil }
            hasher.update(data: Data(hash.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Decides which copy to keep: the files are sorted so the one to keep comes first; every other one is selected.
public enum DuplicatePrioritizer {
    static let copySuffixes = [
        " copy", "-copy", " (copy)", " копия", " (kopie)", " kopie", " (kopia)", " (kópia)", " kópia", " (สำเนา)", " สำเนา",
        " - copie", " copia", " còpia", "-cópia", " kopi", " kopia", " kopija", " kopio", " kopya", " másolat", " salin", " 拷貝",
        " копія", "のコピー", "복사본", "αντίγραφο", "-kopia", "副本", " نسخة", " - עותק", " עותק",
    ]
    static let copyPrefixes = ["copy of ", "copy ", "копия ", "bản sao ", "cópia de ", "salinan ", "نسخة "]

    public static func sortedForKeeping(_ files: [ScannedFile], downloads: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads")) -> [ScannedFile] {
        let downloadsPath = downloads.standardizedFileURL.path + "/"
        return files.sorted { a, b in
            // 1. Copies in Downloads are removed first.
            let aDL = a.path.hasPrefix(downloadsPath), bDL = b.path.hasPrefix(downloadsPath)
            if aDL != bDL { return !aDL }
            // 2. The higher copy number ("Photo 2", "Photo copy 3") goes; no number is kept.
            let aCopy = copyNumber(a.name), bCopy = copyNumber(b.name)
            if aCopy != bCopy { return (aCopy ?? -1) < (bCopy ?? -1) }
            // 3. The most recently modified copy is kept.
            if let am = a.modified, let bm = b.modified, am != bm { return am > bm }
            // 4. The shallowest path is kept.
            let aDepth = a.url.pathComponents.count, bDepth = b.url.pathComponents.count
            if aDepth != bDepth { return aDepth < bDepth }
            // 5. The longer name is kept.
            let aLen = (a.name as NSString).deletingPathExtension.count, bLen = (b.name as NSString).deletingPathExtension.count
            if aLen != bLen { return aLen > bLen }
            // 6. Alphabetical path order.
            return a.path.compare(b.path, options: .numeric) == .orderedAscending
        }
    }

    /// `Report 2.pdf` → 2, `Report copy.pdf` → 1, `Report copy 3.pdf` → 3, `Report.pdf` → nil.
    static func copyNumber(_ fileName: String) -> Int? {
        var stem = (fileName as NSString).deletingPathExtension
        var number: Int?
        let digits = stem.reversed().prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty, digits.count < stem.count {
            number = Int(String(digits.reversed()))
            stem = String(stem.dropLast(digits.count))
            stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: " -_+()"))
        }
        let lower = stem.lowercased()
        let hasMarker = copySuffixes.contains { lower.hasSuffix($0) } || copyPrefixes.contains { lower.hasPrefix($0) }
        if hasMarker { return number ?? 1 }
        // A bare trailing number after a space ("Photo 2") is how Finder numbers copies.
        if number != nil, (fileName as NSString).deletingPathExtension.dropLast(digits.count).last == " " { return number }
        return nil
    }
}

/// Parallel map over files, bounded to the core count, for hashing.
enum ConcurrentMap {
    static func map<T: Sendable, R: Sendable>(_ items: [T], isCancelled: @escaping @Sendable () -> Bool,
                                              progress: @escaping @Sendable (Int, Int) -> Void, _ transform: @escaping @Sendable (T) -> R?) -> [R?] {
        let box = ResultBox<R>(count: items.count)
        DispatchQueue.concurrentPerform(iterations: items.count) { index in
            guard !isCancelled() else { return }
            box.set(transform(items[index]), at: index)
            let done = box.increment()
            if done % 50 == 0 || done == items.count { progress(done, items.count) }
        }
        return box.values
    }

    final class ResultBox<R>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [R?]
        private var done = 0
        init(count: Int) { storage = Array(repeating: nil, count: count) }
        func set(_ value: R?, at index: Int) { lock.withLock { storage[index] = value } }
        func increment() -> Int { lock.withLock { done += 1; return done } }
        var values: [R?] { lock.withLock { storage } }
    }
}
