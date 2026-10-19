import Foundation

/// Turns a selection into the paths to remove.
///
/// A selected folder whose whole subtree is removable goes as one item; if anything inside must be spared
/// (cloud-only files, protected or unread folders) the planner descends and removes only its removable parts.
/// Items selected inside an already selected folder are folded into it.
public enum SpaceLensDeletionPlanner {
    public static func plan(_ selected: [SpaceLensNode]) -> [SpaceLensNode] {
        let roots = selected.filter { node in !selected.contains { $0 !== node && node.isDescendant(of: $0) } }
        return roots.flatMap(expand)
    }

    static func expand(_ node: SpaceLensNode) -> [SpaceLensNode] {
        guard node.isSelectable else { return [] }
        if !node.containsSparedItems { return [node] }
        return node.children.flatMap(expand)
    }
}

public struct SpaceLensRemovalResult: Sendable {
    public var node: SpaceLensNode
    public var error: String?
    public var succeeded: Bool { error == nil }
}

public enum SpaceLensRemover {
    /// Moves each planned item to the Trash; Space Lens deals with the user's own documents, so mistakes stay recoverable.
    public static func remove(_ nodes: [SpaceLensNode], progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> [SpaceLensRemovalResult] {
        nodes.enumerated().map { index, node in
            progress(index, nodes.count)
            do {
                // A folded "smaller items" entry stands for several real items in its folder.
                for path in node.memberPaths {
                    guard FileManager.default.isDeletableFile(atPath: path) else {
                        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
                    }
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                }
                return SpaceLensRemovalResult(node: node, error: nil)
            } catch {
                return SpaceLensRemovalResult(node: node, error: error.localizedDescription)
            }
        }
    }
}
