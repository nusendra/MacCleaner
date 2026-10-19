import Foundation

/// A group of strings that share a relevance weight, e.g. all keywords of a tool.
/// `tag` is reported back in `LookupMatch.matchedTags` when this group wins a query token.
public struct WeightedStrings: Hashable, Sendable {
    public var weight: Int
    public var values: [String]
    public var tag: String?

    public init(weight: Int, values: [String], tag: String? = nil) {
        self.weight = weight
        self.values = values
        self.tag = tag
    }
}

/// A searchable record: an identifier plus its weighted text sources.
public struct LookupDocument<ID: Hashable & Sendable>: Hashable, Sendable {
    public var id: ID
    public var sources: [WeightedStrings]

    public init(id: ID, sources: [WeightedStrings]) {
        self.id = id
        self.sources = sources
    }
}

/// A scored hit returned by `LookupEngine.search(_:)`.
public struct LookupMatch<ID: Hashable & Sendable>: Hashable, Sendable {
    public var id: ID
    public var score: Double
    public var matchedTags: Set<String>

    public init(id: ID, score: Double, matchedTags: Set<String>) {
        self.id = id
        self.score = score
        self.matchedTags = matchedTags
    }
}
