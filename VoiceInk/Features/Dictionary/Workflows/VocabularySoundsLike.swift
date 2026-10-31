import Foundation

/// Optional "sounds like" spellings for a vocabulary term, adapted from Hex's vocabulary limits.
enum VocabularySoundsLike {
    static let maximumCount = 16
    static let maximumLength = 64

    struct Normalized: Equatable {
        let spellings: [String]
        /// True when a spelling was dropped for exceeding the count or length limit.
        let wasClamped: Bool
    }

    /// Splits comma-separated input into whitespace-collapsed, nonempty spellings.
    static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { clean(String($0)) }.filter { !$0.isEmpty }
    }

    static func serialize(_ spellings: [String]) -> String {
        spellings.joined(separator: ", ")
    }

    /// Keeps the spellings that fit: unique ignoring case, different from the term, within the limits.
    static func normalize(_ spellings: [String], term: String) -> Normalized {
        let termKey = key(for: term)
        var seen = Set<String>()
        var kept: [String] = []
        var wasClamped = false
        for spelling in spellings.flatMap(parse) {
            let spellingKey = key(for: spelling)
            guard spellingKey != termKey, !seen.contains(spellingKey) else { continue }
            guard spelling.count <= maximumLength, kept.count < maximumCount else {
                wasClamped = true
                continue
            }
            seen.insert(spellingKey)
            kept.append(spelling)
        }
        return Normalized(spellings: kept, wasClamped: wasClamped)
    }

    /// One prompt entry, following Hex's wording: `term (may be transcribed as a, b)`.
    static func promptEntry(term: String, spellings: [String]) -> String {
        spellings.isEmpty ? term : "\(term) (may be transcribed as \(spellings.joined(separator: ", ")))"
    }

    static let promptGuidance =
        "Spellings after \"may be transcribed as\" are likely mistranscriptions of their term; write the term instead when the speaker means it."

    static func key(for text: String) -> String {
        (clean(text).precomposedStringWithCanonicalMapping as NSString).folding(options: .caseInsensitive, locale: nil)
    }

    private static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
