import Foundation

/// Folds text so "Café", "CAFE" and full-width "ＣＡＦＥ" compare equal.
public struct LookupTextNormalizer: Sendable {
    public var locale: Locale

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    public func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
            .lowercased()
    }
}

/// Splits normalized text into unique tokens, preserving first-seen order.
public struct LookupTokenizer: Sendable {
    /// Anything that is not a letter or digit separates tokens ("clean-up" -> "clean", "up").
    public var separatorCharacters: CharacterSet

    public init(separatorCharacters: CharacterSet = CharacterSet.alphanumerics.inverted) {
        self.separatorCharacters = separatorCharacters
    }

    public func tokens(in text: String) -> [String] {
        var seen = Set<String>()
        return spaced(text)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { seen.insert($0).inserted }
    }

    /// The text with every separator replaced by a single space, used for phrase matching.
    public func phrase(from text: String) -> String {
        spaced(text).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private func spaced(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            separatorCharacters.contains($0) ? " " : $0
        }))
    }
}
