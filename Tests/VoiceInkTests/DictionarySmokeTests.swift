import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class DictionarySmokeTests: XCTestCase {
    func testVocabularyPrecedesWordReplacementsInSectionSelector() {
        let sections = DictionarySettingsView.DictionarySection.allCases

        let titles = sections.map(\.rawValue)

        XCTAssertEqual(titles, ["Vocabulary", "Word Replacements"])
    }

    func testExistingWordReplacementStillRuns() throws {
        let schema = Schema([WordReplacement.self])
        let configuration = ModelConfiguration("dictionary", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        context.insert(WordReplacement(originalText: "web socket", replacementText: "WebSocket"))
        try context.save()

        let result = WordReplacementService.shared.applyReplacements(
            to: "The web socket is open.", using: context
        )

        XCTAssertEqual(result, "The WebSocket is open.")
    }
    func testAutoLearnSuggestionAddsReplacementWithoutChangingSectionedVocabulary() async throws {
        let schema = Schema([VocabularyWord.self, VocabularySection.self, WordReplacement.self])
        let configuration = ModelConfiguration("dictionary", schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: configuration)
        let context = ModelContext(container)
        let section = VocabularySection(name: "Work", sectionDescription: "Product names")
        context.insert(section)
        context.insert(VocabularyWord(word: "VoiceInk", sectionID: section.id))
        try context.save()
        let store = WordReplacementStore(modelContainer: container)
        let suggestion = AutoLearnSuggestion(
            replacementText: "VoiceInk", originals: [.init(id: UUID(), text: "voice ink")]
        )

        let applied = try await store.apply(suggestion)

        let reader = ModelContext(container)
        let words = try reader.fetch(FetchDescriptor<VocabularyWord>())
        let replacements = try reader.fetch(FetchDescriptor<WordReplacement>())
        XCTAssertTrue(applied)
        XCTAssertEqual(words.map(\.word), ["VoiceInk"])
        XCTAssertEqual(words.map(\.sectionID), [section.id])
        XCTAssertEqual(replacements.map(\.replacementText), ["VoiceInk"])
    }

}
