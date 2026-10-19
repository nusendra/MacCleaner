import Testing
@testable import LookupService

private func doc(_ id: String, title: String, keywords: [String] = [], description: String = "") -> LookupDocument<String> {
    LookupDocument(id: id, sources: [
        WeightedStrings(weight: 120, values: [title], tag: "title"),
        WeightedStrings(weight: 60, values: [description], tag: "description"),
        WeightedStrings(weight: 50, values: keywords, tag: "search_keywords"),
    ])
}

@Suite struct TextProcessingTests {
    @Test func foldsCaseDiacriticsAndWidth() {
        let normalizer = LookupTextNormalizer(locale: .init(identifier: "en_US"))
        #expect(normalizer.normalize("Café") == "cafe")
        #expect(normalizer.normalize("ＣＡＦＥ") == "cafe")
    }

    @Test func tokenizesOnPunctuationAndDeduplicatesInOrder() {
        let tokenizer = LookupTokenizer()
        #expect(tokenizer.tokens(in: "large & old-files, large") == ["large", "old", "files"])
        #expect(tokenizer.phrase(from: "large &  old-files") == "large old files")
    }
}

@Suite struct ScoringPolicyTests {
    let policy = LookupScoringPolicy()

    @Test func ranksExactOverPrefixOverSubstring() {
        #expect(policy.tokenScore("junk", against: ["junk"]) == 1.0)
        #expect(policy.tokenScore("jun", against: ["junk"]) == 0.82)
        #expect(policy.tokenScore("unk", against: ["junk"]) == 0.5)
        #expect(policy.tokenScore("xyz", against: ["junk"]) == nil)
    }
}

@Suite struct LookupEngineTests {
    @Test func emptyQueryReturnsNothing() {
        let engine = LookupEngine(documents: [doc("a", title: "System Junk")])
        #expect(engine.search("  ").isEmpty)
        #expect(engine.search("--").isEmpty)
    }

    @Test func titleHitOutranksKeywordHit() {
        let engine = LookupEngine(documents: [
            doc("keyword", title: "Cleanup", keywords: ["cache"]),
            doc("title", title: "Cache Cleaner"),
        ])
        let results = engine.search("cache")
        #expect(results.map(\.id) == ["title", "keyword"])
        #expect(results[0].score == 120 + 5) // exact title token + phrase bonus
        #expect(results[0].matchedTags == ["title"])
        #expect(results[1].matchedTags == ["search_keywords"])
    }

    @Test func everyQueryTokenMustMatch() {
        let engine = LookupEngine(documents: [doc("a", title: "System Junk")])
        #expect(engine.search("system junk").count == 1)
        #expect(engine.search("system photos").isEmpty)
    }

    @Test func multiTokenScoresSumWithPhraseBonus() throws {
        let engine = LookupEngine(documents: [doc("a", title: "System Junk")])
        let match = try #require(engine.search("system junk").first)
        #expect(match.score == 120 + 120 + 5)
        let partial = try #require(engine.search("junk sys").first)
        #expect(partial.score == 120 + 120 * 0.82)
    }

    @Test func tiesKeepDocumentOrder() {
        let engine = LookupEngine(documents: [
            doc("first", title: "Trash"),
            doc("second", title: "Trash"),
        ])
        #expect(engine.search("trash").map(\.id) == ["first", "second"])
    }

    @Test func matchesAccentedAndCasedInput() {
        let engine = LookupEngine(documents: [doc("a", title: "Résumé Finder")], normalizer: .init(locale: .init(identifier: "en_US")))
        #expect(engine.search("RESUME").first?.id == "a")
    }

    @Test func clientSearchesAfterIndexing() async {
        let client = LookupClient<String>()
        await client.index([doc("a", title: "Space Lens")])
        #expect(await client.search("lens").map(\.id) == ["a"])
    }
}

private struct FolderNode: SearchableNode {
    var searchableDescription: String
    var children: [FolderNode] = []
}

@Suite struct NodeSearchFilterTests {
    @Test func keepsAncestorsOfMatchingChildren() {
        let tree = FolderNode(searchableDescription: "Library", children: [
            FolderNode(searchableDescription: "Caches", children: [FolderNode(searchableDescription: "com.apple.Safari")]),
            FolderNode(searchableDescription: "Logs"),
        ])
        let filter = NodeSearchFilter(searchTerm: "safari")
        #expect(filter.matchesSelfOrAnyChild(tree))
        #expect(filter.matchesSelfOrAnyChild(tree.children[0]))
        #expect(!filter.matchesSelfOrAnyChild(tree.children[1]))
    }
}
