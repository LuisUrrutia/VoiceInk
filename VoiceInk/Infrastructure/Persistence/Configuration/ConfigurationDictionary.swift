import Foundation
import SwiftData

struct ConfigurationDictionary: Codable, Equatable {
    struct Section: Codable, Equatable {
        let id: UUID
        let name: String
        let description: String
    }

    struct Word: Codable, Equatable {
        let term: String
        let sectionID: UUID?
        let addedAt: Double?
    }

    struct Replacement: Codable, Equatable {
        let id: UUID?
        let sources: [String]
        let replacement: String
        let addedAt: Double?
    }

    let sections: [Section]
    let vocabulary: [Word]
    let replacements: [Replacement]

    func validate() throws {
        try ConfigurationPreferences.requireUnique(sections.map(\.id), key: "dictionary.sections")
        try ConfigurationPreferences.requireUnique(
            sections.map { WordReplacementVariants.key(for: $0.name) }, key: "dictionary.sections"
        )
        let sectionIDs = Set(sections.map(\.id))
        guard sections.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
            vocabulary.allSatisfy({
                !$0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ($0.sectionID == nil || sectionIDs.contains($0.sectionID!))
                    && ($0.addedAt?.isFinite != false)
            })
        else { throw ConfigurationError.invalid("Dictionary terms need valid sections and nonempty names.") }
        try ConfigurationPreferences.requireUnique(
            vocabulary.map { VocabularyWordIdentity(word: $0.term, sectionID: $0.sectionID) }, key: "dictionary.vocabulary"
        )
        try ConfigurationPreferences.requireUnique(replacements.compactMap(\.id), key: "dictionary.replacements")
        // Existing stores can contain conflicting or cyclic rules; the replacement plan preserves them.
        for rule in replacements {
            guard !rule.sources.isEmpty, !rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                rule.addedAt?.isFinite != false
            else { throw ConfigurationError.invalid("Replacement rules need sources and a replacement.") }
            var sourceKeys = Set<String>()
            for source in rule.sources {
                let key = WordReplacementVariants.key(for: source)
                guard !key.isEmpty, !source.contains(","), sourceKeys.insert(key).inserted
                else { throw ConfigurationError.invalid("Sources within a replacement rule must be nonempty, unique and comma-free.") }
            }
        }
    }

    @MainActor
    static func capture(in context: ModelContext) throws -> Self {
        let sections = try context.fetch(FetchDescriptor<VocabularySection>()).map {
            Section(id: $0.id, name: $0.name, description: $0.sectionDescription)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let vocabulary = try context.fetch(FetchDescriptor<VocabularyWord>()).map {
            Word(term: $0.word, sectionID: $0.sectionID, addedAt: $0.dateAdded.timeIntervalSince1970)
        }.sorted {
            let left = ($0.sectionID?.uuidString ?? "", $0.term)
            let right = ($1.sectionID?.uuidString ?? "", $1.term)
            return left < right
        }
        let replacements = try context.fetch(FetchDescriptor<WordReplacement>()).map {
            Replacement(id: $0.id, sources: WordReplacementVariants.parse($0.originalText),
                        replacement: $0.replacementText, addedAt: $0.dateAdded.timeIntervalSince1970)
        }.sorted { ($0.id?.uuidString ?? "") < ($1.id?.uuidString ?? "") }
        return Self(sections: sections, vocabulary: vocabulary, replacements: replacements)
    }

    @MainActor
    func apply(to container: ModelContainer) throws {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let oldSections = try context.fetch(FetchDescriptor<VocabularySection>())
        let oldWords = try context.fetch(FetchDescriptor<VocabularyWord>())
        let oldRules = try context.fetch(FetchDescriptor<WordReplacement>())
        let sectionsByID = Dictionary(oldSections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wordsByIdentity = Dictionary(oldWords.map {
            (VocabularyWordIdentity(word: $0.word, sectionID: $0.sectionID), $0)
        }, uniquingKeysWith: { first, _ in first })
        let rulesByID = Dictionary(oldRules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let orderedRules = oldRules.sorted {
            ($0.dateAdded, $0.id.uuidString) < ($1.dateAdded, $1.id.uuidString)
        }
        let rulesBySources = Dictionary(grouping: orderedRules) {
            WordReplacementVariants.parse($0.originalText).map(WordReplacementVariants.key).sorted()
        }
        let explicitRuleIDs = Set(replacements.compactMap(\.id))
        var retained = Set<PersistentIdentifier>()
        do {
            for section in sections {
                if let existing = sectionsByID[section.id] {
                    retained.insert(existing.persistentModelID)
                    if existing.name != section.name { existing.name = section.name }
                    if existing.sectionDescription != section.description { existing.sectionDescription = section.description }
                } else {
                    context.insert(VocabularySection(id: section.id, name: section.name, sectionDescription: section.description))
                }
            }
            for word in vocabulary {
                let identity = VocabularyWordIdentity(word: word.term, sectionID: word.sectionID)
                if let existing = wordsByIdentity[identity] {
                    retained.insert(existing.persistentModelID)
                    if existing.word != word.term { existing.word = word.term }
                    if let date = word.addedAt.map(Date.init(timeIntervalSince1970:)), existing.dateAdded != date { existing.dateAdded = date }
                } else {
                    context.insert(VocabularyWord(word: word.term,
                        dateAdded: word.addedAt.map(Date.init(timeIntervalSince1970:)) ?? Date(), sectionID: word.sectionID))
                }
            }
            for rule in replacements {
                let source = WordReplacementVariants.serialize(rule.sources)
                let destination = WordReplacementVariants.destinationKey(for: rule.replacement)
                let sourceKeys = rule.sources.map(WordReplacementVariants.key).sorted()
                let existing: WordReplacement?
                if let id = rule.id { existing = rulesByID[id] }
                else {
                    let candidates = (rulesBySources[sourceKeys] ?? []).filter {
                        !retained.contains($0.persistentModelID) && !explicitRuleIDs.contains($0.id)
                    }
                    existing = candidates.first { WordReplacementVariants.destinationKey(for: $0.replacementText) == destination }
                        ?? candidates.first
                }
                if let existing, !retained.contains(existing.persistentModelID) {
                    retained.insert(existing.persistentModelID)
                    if existing.originalText != source { existing.originalText = source }
                    if existing.replacementText != destination { existing.replacementText = destination }
                    if let date = rule.addedAt.map(Date.init(timeIntervalSince1970:)), existing.dateAdded != date { existing.dateAdded = date }
                } else {
                    let replacement = WordReplacement(originalText: source, replacementText: destination,
                        dateAdded: rule.addedAt.map(Date.init(timeIntervalSince1970:)) ?? Date())
                    if let id = rule.id { replacement.id = id }
                    context.insert(replacement)
                }
            }
            for word in oldWords where !retained.contains(word.persistentModelID) { context.delete(word) }
            for section in oldSections where !retained.contains(section.persistentModelID) { context.delete(section) }
            for rule in oldRules where !retained.contains(rule.persistentModelID) { context.delete(rule) }
            if context.hasChanges { try context.save() }
        } catch {
            context.rollback()
            throw error
        }
    }
}
