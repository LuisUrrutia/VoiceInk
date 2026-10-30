import Foundation
import SwiftData

@MainActor
final class CustomVocabularyService {
    static let shared = CustomVocabularyService()

    private init() {}

    func loadSavedVocabulary(from context: ModelContext) -> RecordingVocabulary {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        let words = (try? context.fetch(descriptor)) ?? []
        let sections = words.contains { $0.sectionID != nil }
            ? (try? context.fetch(FetchDescriptor<VocabularySection>())) ?? []
            : []
        return RecordingVocabulary(
            savedTerms: words.map(\.word),
            sectionedPrompt: Self.sectionedPrompt(words: words, sections: sections)
        )
    }

    func getCustomVocabulary(from context: ModelContext) -> String {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\VocabularyWord.word)])
        guard let words = try? context.fetch(descriptor), !words.isEmpty else {
            return ""
        }
        let sections = (try? context.fetch(FetchDescriptor<VocabularySection>())) ?? []
        return Self.format(words: words, sections: sections)
    }

    nonisolated static func format(words: [VocabularyWord], sections: [VocabularySection]) -> String {
        if let sectioned = sectionedPrompt(words: words, sections: sections) {
            return sectioned
        }
        let terms = sortedTerms(words).map(\.term)
        guard !terms.isEmpty else { return "" }
        return escapePromptDelimiters("Important Vocabulary: \(terms.joined(separator: ", "))")
    }

    /// Grouped prompt for vocabulary assigned to existing sections; nil when no section has terms.
    nonisolated static func sectionedPrompt(words: [VocabularyWord], sections: [VocabularySection]) -> String? {
        let sortedWords = sortedTerms(words)
        guard !sortedWords.isEmpty else { return nil }

        let sectionByID = sections.reduce(into: [UUID: VocabularySection]()) { result, section in
            result[section.id] = section
        }
        let ungrouped = sortedWords.filter { word in
            guard let id = word.sectionID else { return true }
            return sectionByID[id] == nil
        }.map(\.term)
        let groups = sections.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .compactMap { section -> String? in
                let terms = sortedWords.filter { $0.sectionID == section.id }.map(\.term)
                guard !terms.isEmpty else { return nil }
                let name = section.name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let description = section.sectionDescription.split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
                let heading = description.isEmpty ? name : "\(name) — \(description)"
                return "\(heading): \(terms.joined(separator: ", "))"
            }

        guard !groups.isEmpty else { return nil }
        let ungroupedLine = ungrouped.isEmpty ? [] : ["Other terms: \(ungrouped.joined(separator: ", "))"]
        return escapePromptDelimiters((["Important Vocabulary:"] + ungroupedLine + groups).joined(separator: "\n"))
    }

    nonisolated static func escapePromptDelimiters(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private nonisolated static func sortedTerms(_ words: [VocabularyWord]) -> [(term: String, sectionID: UUID?)] {
        words.map { (term: $0.word.trimmingCharacters(in: .whitespacesAndNewlines), sectionID: $0.sectionID) }
            .filter { !$0.term.isEmpty }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
    }
}
