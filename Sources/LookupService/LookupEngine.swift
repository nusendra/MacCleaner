import Foundation

struct LookupIndexedSource: Sendable {
    var weight: Int
    var tag: String?
    var tokens: Set<String>
    var normalizedValues: [String]
}

struct LookupIndexedRecord<ID: Hashable & Sendable>: Sendable {
    var id: ID
    var sortOrder: Int
    var sources: [LookupIndexedSource]
}

/// In-memory weighted token index.
///
/// Scoring, per record:
/// - every query token must match some source token (AND semantics), otherwise the record is dropped;
/// - a token's score is `source.weight * policy.tokenScore`, taking the best source;
/// - the record score is the sum over query tokens, plus `phraseBonus` when a multi-character
///   query appears verbatim inside one of the record's values.
/// Results are ordered by score (descending), then by original document order.
public struct LookupEngine<ID: Hashable & Sendable>: Sendable {
    public var normalizer: LookupTextNormalizer
    public var tokenizer: LookupTokenizer
    public var scoringPolicy: LookupScoringPolicy
    private var records: [LookupIndexedRecord<ID>] = []

    public init(
        documents: [LookupDocument<ID>] = [],
        normalizer: LookupTextNormalizer = .init(),
        tokenizer: LookupTokenizer = .init(),
        scoringPolicy: LookupScoringPolicy = .init()
    ) {
        self.normalizer = normalizer
        self.tokenizer = tokenizer
        self.scoringPolicy = scoringPolicy
        index(documents)
    }

    public mutating func index(_ documents: [LookupDocument<ID>]) {
        records = documents.enumerated().map { order, document in
            LookupIndexedRecord(id: document.id, sortOrder: order, sources: document.sources.map(indexedSource))
        }
    }

    public func search(_ query: String) -> [LookupMatch<ID>] {
        let normalizedQuery = normalizer.normalize(query)
        let queryTokens = tokenizer.tokens(in: normalizedQuery)
        guard !queryTokens.isEmpty else { return [] }
        let queryPhrase = tokenizer.phrase(from: normalizedQuery)

        var scored: [(match: LookupMatch<ID>, sortOrder: Int)] = []
        for record in records {
            if Task.isCancelled { return [] }
            if let match = score(record, queryTokens: queryTokens, queryPhrase: queryPhrase) {
                scored.append((match, record.sortOrder))
            }
        }
        return scored
            .sorted { lhs, rhs in
                lhs.match.score == rhs.match.score ? lhs.sortOrder < rhs.sortOrder : lhs.match.score > rhs.match.score
            }
            .map(\.match)
    }

    private func indexedSource(_ source: WeightedStrings) -> LookupIndexedSource {
        let normalized = source.values.map { tokenizer.phrase(from: normalizer.normalize($0)) }
        return LookupIndexedSource(
            weight: source.weight,
            tag: source.tag,
            tokens: Set(normalized.flatMap { tokenizer.tokens(in: $0) }),
            normalizedValues: normalized
        )
    }

    private func score(_ record: LookupIndexedRecord<ID>, queryTokens: [String], queryPhrase: String) -> LookupMatch<ID>? {
        var total = 0.0
        var matchedTags = Set<String>()

        for token in queryTokens {
            var best: (score: Double, tag: String?)?
            for source in record.sources {
                guard let tokenScore = scoringPolicy.tokenScore(token, against: source.tokens) else { continue }
                let weighted = Double(source.weight) * tokenScore
                if weighted > 0, weighted > (best?.score ?? 0) {
                    best = (weighted, source.tag)
                }
            }
            guard let best else { return nil }
            total += best.score
            if let tag = best.tag { matchedTags.insert(tag) }
        }

        total += phraseBonus(queryPhrase, in: record)
        guard total > 0 else { return nil }
        return LookupMatch(id: record.id, score: total, matchedTags: matchedTags)
    }

    private func phraseBonus(_ phrase: String, in record: LookupIndexedRecord<ID>) -> Double {
        guard phrase.count > 1 else { return 0 }
        let hit = record.sources.contains { $0.normalizedValues.contains { $0.contains(phrase) } }
        return hit ? scoringPolicy.phraseBonus : 0
    }
}

/// Thread-safe wrapper so the index can be built and queried off the main actor.
public actor LookupClient<ID: Hashable & Sendable> {
    private var engine: LookupEngine<ID>

    public init(engine: LookupEngine<ID> = .init()) {
        self.engine = engine
    }

    public func index(_ documents: [LookupDocument<ID>]) {
        engine.index(documents)
    }

    public func search(_ query: String) -> [LookupMatch<ID>] {
        engine.search(query)
    }
}
