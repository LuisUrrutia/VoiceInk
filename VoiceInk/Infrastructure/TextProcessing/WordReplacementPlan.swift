import Foundation

public struct ReplacementRule: Equatable {
    public let id: String
    public let sources: [String]
    public let replacement: String
    public let dateAdded: Date
    public let enabled: Bool

    public init(id: String, sources: [String], replacement: String, dateAdded: Date = .distantPast, enabled: Bool = true) {
        self.id = id
        self.sources = sources
        self.replacement = replacement
        self.dateAdded = dateAdded
        self.enabled = enabled
    }
}

public struct WordReplacementPlan {
    private struct PreparedRule {
        let original: String
        let replacement: String
        let regex: NSRegularExpression?
    }
    private let prepared: [PreparedRule]

    public init(rules: [ReplacementRule]) {
        let rules = rules.filter(\.enabled)
        let sortedRules = rules
            .flatMap { record in
                record.sources.filter { !$0.isEmpty }.map {
                    (
                        original: $0,
                        replacement: record.replacement,
                        dateAdded: record.dateAdded,
                        id: record.id
                    )
                }
            }
            .sorted {
                if $0.original.count != $1.original.count {
                    return $0.original.count > $1.original.count
                }
                let leftKey = WordReplacementVariants.key(for: $0.original)
                let rightKey = WordReplacementVariants.key(for: $1.original)
                if leftKey != rightKey {
                    return leftKey < rightKey
                }
                if $0.dateAdded != $1.dateAdded {
                    return $0.dateAdded < $1.dateAdded
                }
                return $0.id < $1.id
            }

        // Preserve every legacy rule. New dictionary mutations prevent source
        // conflicts, but older stores may contain multiple rules for a trigger.
        let prepared = sortedRules.compactMap { rule -> PreparedRule? in
            guard Self.usesWordBoundaries(for: rule.original) else {
                return PreparedRule(original: rule.original, replacement: rule.replacement, regex: nil)
            }

            // Unicode-aware lookarounds treat punctuation as a boundary while
            // preventing matches inside larger words.
            do {
                let escaped = NSRegularExpression.escapedPattern(for: rule.original)
                let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
                let pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
                let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
                return PreparedRule(original: rule.original, replacement: rule.replacement, regex: regex)
            } catch {
                return nil
            }
        }

        self.prepared = prepared
    }

    public func apply(to text: String) -> String {
        var result = text
        for rule in prepared {
            if let regex = rule.regex {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                        withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement))
            } else {
                result = result.replacingOccurrences(of: rule.original, with: rule.replacement, options: .caseInsensitive)
            }
        }
        return result
    }

    private static func usesWordBoundaries(for text: String) -> Bool {
        // Returns false for languages without spaces (CJK, Thai), true for spaced languages
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul Syllables
            0x0E00...0x0E7F,  // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}
