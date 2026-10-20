import Foundation
import JunkCleanup
import UniformTypeIdentifiers

/// A regular file (or bundle) found under the scan root.
public struct ScannedFile: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var modified: Date?
    public var created: Date?
    public var isBundle: Bool
    /// Device and inode, so hard links to the same data are not reported as duplicates.
    var fileID: FileID

    struct FileID: Hashable, Sendable { var device: Int32; var inode: UInt64 }

    public var path: String { url.path }
    public var name: String { url.lastPathComponent }
}

/// CleanMyMac's "Organize" ignore rules: the same names, extensions and folders are skipped.
public struct ScanRules: Sendable {
    public static let minimumFileSize: Int64 = 102_400

    static let ignoredNamePattern = try! NSRegularExpression(
        pattern: [#"\.git"#, #"\.svn"#, #"\.Trash"#, #"\.DS_Store"#, "credits.?", "infoplist.?", "web-inf.?", #"backups\.backupdb"#,
                  "licence.?", "license.?", "node_modules", "gems", "bower_components"].map { "(\($0))" }.joined(separator: "|"),
        options: .caseInsensitive
    )

    static let ignoredExtensions: Set<String> = Set("""
        framework build lproj a so h pch c hpp h++ cpp c++ m swift java class idea py rb php css js json jar lib dylib dll ocx \
        pth db rpl hds info def properties proofingtool bup ar tmp hg vsd xsd xslt xsl entitlements xcconfig sparsebundle dsym \
        cer crt applescript version asset prefab unity html scss sh bash scala sc cs cake coffee cshtml csx ts vim vue plist yml \
        yaml gradle md ruby gemfile gem sql photoslibrary musiclibrary xcassets
        """.split(separator: " ").map { $0.lowercased() })

    /// Extra extensions that never count as similar images.
    static let ignoredImageExtensions: Set<String> = ["psd", "psb"]

    var ignoredPrefixes: [String]
    /// Without Full Disk Access these are not opened (macOS would block on a consent prompt).
    var protectedPaths: Set<String>

    public init(home: URL = JunkPaths.current.home, root: URL, hasFullDiskAccess: Bool = Permissions.hasFullDiskAccess) {
        let homePath = home.standardizedFileURL.path
        ignoredPrefixes = ["/System/", "/Library/", homePath + "/Library/", homePath + "/Music/Music/", homePath + "/Music/iTunes/"]
        let rootPath = root.standardizedFileURL.path
        let protected = ["Desktop", "Documents", "Downloads", "Pictures/Photos Library.photoslibrary"].map { homePath + "/" + $0 }
        // A folder the user picked in an open panel counts as consent, so it and its contents are allowed.
        protectedPaths = hasFullDiskAccess ? [] : Set(protected.filter { rootPath != $0 && !rootPath.hasPrefix($0 + "/") })
    }

    func isIgnored(name: String, path: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.ignoredExtensions.contains(ext) { return true }
        if ignoredPrefixes.contains(where: { (path + "/").hasPrefix($0) }) { return true }
        if protectedPaths.contains(path) { return true }
        return Self.ignoredNamePattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }
}

enum FileEnumerator {
    static let keys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isUbiquitousItemKey, .isHiddenKey,
        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
    ]

    /// Every regular file and bundle under `root` that passes the rules, at least the minimum size.
    static func files(under root: URL, rules: ScanRules, isCancelled: () -> Bool, found: (Int) -> Void) -> [ScannedFile] {
        var result: [ScannedFile] = []
        var stack = [root]
        while let directory = stack.popLast() {
            if isCancelled() { return [] }
            let children = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
            for url in children {
                let path = url.path
                guard !rules.isIgnored(name: url.lastPathComponent, path: path),
                      let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isSymbolicLink != true, values.isHidden != true, values.isUbiquitousItem != true
                else { continue }
                if values.isPackage == true {
                    if let bundle = scannedBundle(url, values) { result.append(bundle) }
                } else if values.isDirectory == true {
                    stack.append(url)
                } else if values.isRegularFile == true, let size = values.fileSize, Int64(size) >= ScanRules.minimumFileSize {
                    var info = stat()
                    guard lstat(path, &info) == 0 else { continue }
                    result.append(ScannedFile(url: url, size: Int64(size), modified: values.contentModificationDate, created: values.creationDate,
                                              isBundle: false, fileID: .init(device: info.st_dev, inode: info.st_ino)))
                    if result.count % 500 == 0 { found(result.count) }
                }
            }
        }
        found(result.count)
        return result
    }

    /// Bundles (apps, packages) are compared as a whole: their size is the sum of their files.
    private static func scannedBundle(_ url: URL, _ values: URLResourceValues) -> ScannedFile? {
        var size: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])
        while let file = enumerator?.nextObject() as? URL {
            if let v = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { size += Int64(v.fileSize ?? 0) }
        }
        guard size >= ScanRules.minimumFileSize else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return ScannedFile(url: url, size: size, modified: values.contentModificationDate, created: values.creationDate,
                           isBundle: true, fileID: .init(device: info.st_dev, inode: info.st_ino))
    }
}

public enum DuplicateKind: String, CaseIterable, Sendable {
    case applications = "Applications", archives = "Archives", audio = "Audio", documents = "Documents"
    case pictures = "Pictures", videos = "Videos", other = "Other"

    static func of(_ url: URL) -> DuplicateKind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .applications }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .pictures }
        if type.conforms(to: .movie) { return .videos }
        if type.conforms(to: .text) || type.conforms(to: .content) { return .documents }
        return .other
    }
}
