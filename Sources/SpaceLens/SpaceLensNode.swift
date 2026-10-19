import Foundation

/// One file or folder in a Space Lens tree. Built once by the scanner; afterwards only `removeFromTree` mutates it
/// (on the main actor), so it is shared across threads as an immutable snapshot.
///
/// Kept small on purpose: a disk scan creates millions of these. Nodes store their name, not a URL (paths are
/// rebuilt from the parent chain), and the parent link is unowned so no weak-reference side tables are allocated.
public final class SpaceLensNode: Identifiable, @unchecked Sendable {
    public enum Kind: UInt8, Sendable {
        case file
        case directory
        /// Space macOS can free on its own (local snapshots, caches); shown, never deleted.
        case purgeable
        /// A privacy-protected folder that was not opened because Full Disk Access is missing.
        case needsAccess
        /// The smallest items of one folder folded into a single entry to keep memory bounded.
        case smallerFiles
    }

    public enum CloudStatus: UInt8, Sendable {
        case notCloud
        /// Synced and downloaded: deleting it removes it from the cloud too.
        case local
        /// Cloud-only placeholder: takes no local space and cannot be deleted here.
        case evicted
    }

    public let name: String
    public let kind: Kind
    public let cloud: CloudStatus
    public let isProtected: Bool
    /// For `.smallerFiles`, the names (in the parent folder) of the items folded together.
    public let foldedNames: [String]
    public private(set) var size: Int64
    public private(set) var children: [SpaceLensNode]
    public private(set) unowned(unsafe) var parent: SpaceLensNode?
    /// True if this node or anything below it must survive a delete (cloud-only, protected, purgeable, unread).
    public private(set) var containsSparedItems: Bool
    /// Only the root (and pseudo entries) store a full path; everything else derives it.
    private let storedPath: String?
    /// A small folder whose contents were dropped after sizing; `SpaceLensScanner.expand` reads them back.
    public private(set) var isCollapsed = false

    public var id: ObjectIdentifier { ObjectIdentifier(self) }
    public var isDirectory: Bool { kind == .directory }
    public var isSelectable: Bool {
        !isProtected && kind != .purgeable && kind != .needsAccess && cloud != .evicted
    }

    public var path: String {
        if let storedPath { return storedPath }
        if kind == .smallerFiles, let parent { return parent.path }
        guard let parent else { return name }
        let base = parent.path
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// The real files and folders this node stands for.
    public var memberPaths: [String] {
        guard kind == .smallerFiles else { return [path] }
        let base = path.hasSuffix("/") ? path : path + "/"
        return foldedNames.map { base + $0 }
    }

    public var displayName: String {
        switch kind {
        case .smallerFiles: "\(foldedNames.count) smaller items"
        default: name
        }
    }

    init(name: String, path: String? = nil, kind: Kind, size: Int64 = 0, cloud: CloudStatus = .notCloud,
         isProtected: Bool = false, foldedNames: [String] = [], children: [SpaceLensNode] = []) {
        self.name = name
        storedPath = path
        self.kind = kind
        self.cloud = cloud
        self.isProtected = isProtected
        self.foldedNames = foldedNames
        self.children = children.sorted { $0.size > $1.size }
        self.size = kind == .directory ? children.reduce(size) { $0 + $1.size } : size
        let selfSpared = isProtected || kind == .purgeable || kind == .needsAccess || cloud == .evicted
        containsSparedItems = selfSpared || children.contains(where: \.containsSparedItems)
        for child in self.children { child.parent = self }
    }

    /// A folder whose size is known but whose contents are not kept.
    static func collapsedFolder(name: String, size: Int64, cloud: CloudStatus) -> SpaceLensNode {
        let node = SpaceLensNode(name: name, kind: .directory, size: size, cloud: cloud)
        node.isCollapsed = true
        return node
    }

    /// Fills a collapsed folder with freshly scanned contents.
    func adoptChildren(of scanned: SpaceLensNode) {
        children = scanned.children
        for child in children { child.parent = self }
        isCollapsed = false
        containsSparedItems = isProtected || children.contains(where: \.containsSparedItems)
    }

    /// Test and pseudo-entry convenience: a node addressed by a full URL.
    convenience init(url: URL, kind: Kind, size: Int64 = 0, cloud: CloudStatus = .notCloud, isProtected: Bool = false, children: [SpaceLensNode] = []) {
        self.init(name: url.lastPathComponent, path: url.path, kind: kind, size: size, cloud: cloud, isProtected: isProtected, children: children)
    }

    /// Ancestors from the root down to (and including) this node.
    public var lineage: [SpaceLensNode] {
        var chain: [SpaceLensNode] = [self]
        while let parent = chain.last?.parent { chain.append(parent) }
        return chain.reversed()
    }

    public func isDescendant(of other: SpaceLensNode) -> Bool {
        var current = parent
        while let node = current {
            if node === other { return true }
            current = node.parent
        }
        return false
    }

    /// Detaches this node after it was deleted and shrinks every ancestor by its size.
    public func removeFromTree() {
        guard let parent else { return }
        parent.children.removeAll { $0 === self }
        var ancestor: SpaceLensNode? = parent
        while let node = ancestor {
            node.size -= size
            node.children.sort { $0.size > $1.size }
            node.containsSparedItems = node.isProtected || node.children.contains(where: \.containsSparedItems)
            ancestor = node.parent
        }
        self.parent = nil
    }
}
