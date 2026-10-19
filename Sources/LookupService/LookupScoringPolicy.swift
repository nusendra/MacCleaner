import Foundation

/// How strongly a query token matches a candidate token, and the bonus for whole-phrase hits.
public struct LookupScoringPolicy: Sendable {
    public var exactMatch: Double
    public var prefixMatch: Double
    public var substringMatch: Double
    public var phraseBonus: Double

    public init(exactMatch: Double = 1.0, prefixMatch: Double = 0.82, substringMatch: Double = 0.5, phraseBonus: Double = 5.0) {
        self.exactMatch = exactMatch
        self.prefixMatch = prefixMatch
        self.substringMatch = substringMatch
        self.phraseBonus = phraseBonus
    }

    /// Best score of `queryToken` against any token in `candidates`, or nil if none match.
    public func tokenScore(_ queryToken: String, against candidates: Set<String>) -> Double? {
        if candidates.contains(queryToken) { return exactMatch }
        var best: Double?
        for candidate in candidates {
            let score: Double
            if candidate.hasPrefix(queryToken) {
                score = prefixMatch
            } else if candidate.contains(queryToken) {
                score = substringMatch
            } else {
                continue
            }
            if score > (best ?? 0) { best = score }
            if score == prefixMatch { break }
        }
        return best
    }
}
