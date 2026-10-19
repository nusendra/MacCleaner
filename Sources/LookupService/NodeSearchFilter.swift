import Foundation

/// A node in a scan-result tree (folder, app, cache group...).
public protocol SearchableNode {
    var searchableDescription: String { get }
    var children: [Self] { get }
}

/// Live filter for large result trees: a node stays visible if it, or any descendant, contains the term.
public struct NodeSearchFilter: Sendable {
    /// Debounce to use while typing over large trees.
    public static let largeTreeDebounce: Duration = .milliseconds(500)

    public var searchTerm: String

    public init(searchTerm: String) {
        self.searchTerm = searchTerm
    }

    public func matches<Node: SearchableNode>(_ node: Node) -> Bool {
        searchTerm.isEmpty || node.searchableDescription.localizedCaseInsensitiveContains(searchTerm)
    }

    public func matchesSelfOrAnyChild<Node: SearchableNode>(_ node: Node) -> Bool {
        matches(node) || node.children.contains { matchesSelfOrAnyChild($0) }
    }
}
