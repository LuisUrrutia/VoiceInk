import SwiftData
import XCTest
@testable import VoiceInk

/// The dictionary store schema before vocabulary terms gained "sounds like" spellings.
private enum DictionarySchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [VocabularyWord.self, WordReplacement.self, VocabularySection.self]
    }

    @Model
    final class VocabularyWord {
        var word: String = ""
        var dateAdded: Date = Date()
        var sectionID: UUID?

        init(word: String, dateAdded: Date = Date(), sectionID: UUID? = nil) {
            self.word = word
            self.dateAdded = dateAdded
            self.sectionID = sectionID
        }
    }

    @Model
    final class WordReplacement {
        var id: UUID = UUID()
        var originalText: String = ""
        var replacementText: String = ""
        var dateAdded: Date = Date()
        var isEnabled: Bool = true

        init(originalText: String, replacementText: String) {
            self.originalText = originalText
            self.replacementText = replacementText
        }
    }

    @Model
    final class VocabularySection {
        var id: UUID = UUID()
        var name: String = ""
        var sectionDescription: String = ""

        init(id: UUID, name: String, sectionDescription: String) {
            self.id = id
            self.name = name
            self.sectionDescription = sectionDescription
        }
    }
}

@MainActor
final class VocabularySoundsLikeTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([VocabularyWord.self, VocabularySection.self, WordReplacement.self])
        let configuration = ModelConfiguration("dictionary", schema: schema, isStoredInMemoryOnly: true)
        return ModelContext(try ModelContainer(for: schema, configurations: configuration))
    }

    // MARK: - Normalization

    func testSpellingsAreCleanedUniqueAndDifferentFromTheirTerm() {
        let parsed = VocabularySoundsLike.parse(" voice  ink,, VOICE INK , voiceink, voicing ,")

        let normalized = VocabularySoundsLike.normalize(parsed, term: "VoiceInk")

        XCTAssertEqual(parsed, ["voice ink", "VOICE INK", "voiceink", "voicing"])
        XCTAssertEqual(normalized, .init(spellings: ["voice ink", "voicing"], wasClamped: false))
        XCTAssertTrue(VocabularySoundsLike.parse(" , ").isEmpty)
    }

    func testSpellingsPastTheLimitsKeepWhatFits() {
        let long = String(repeating: "x", count: VocabularySoundsLike.maximumLength + 1)
        let fitting = String(repeating: "y", count: VocabularySoundsLike.maximumLength)
        let many = (1...20).map { "spelling \($0)" }

        let normalized = VocabularySoundsLike.normalize([long, fitting] + many, term: "Term")

        XCTAssertTrue(normalized.wasClamped)
        XCTAssertEqual(normalized.spellings, [fitting] + many.prefix(VocabularySoundsLike.maximumCount - 1))
        XCTAssertEqual(normalized.spellings.count, VocabularySoundsLike.maximumCount)
    }

    // MARK: - Prompts

    func testGroupedPromptNamesSpellingsWithTheirTerms() {
        let section = VocabularySection(name: "People", sectionDescription: "Teammates")
        let words = [
            VocabularyWord(word: "Urrutia", sectionID: section.id, soundsLike: ["ooh root ya", "Urutia"]),
            VocabularyWord(word: "Ana", sectionID: section.id),
            VocabularyWord(word: "VoiceInk", soundsLike: ["voice ink"]),
        ]

        let prompt = CustomVocabularyService.format(words: words, sections: [section])

        XCTAssertEqual(
            prompt,
            "Important Vocabulary:\nOther terms: VoiceInk (may be transcribed as voice ink)\n"
                + "People — Teammates: Ana, Urrutia (may be transcribed as ooh root ya, Urutia)"
        )
    }

    func testFlatEnhancementPromptAddsSpellingsWithoutChangingTranscriptionTerms() throws {
        let context = try makeContext()
        XCTAssertNil(DictionaryService.addVocabularyWords(
            "VoiceInk", existing: [], context: context, soundsLike: "voice ink, <voicing>"
        ))
        XCTAssertNil(DictionaryService.addVocabularyWords(
            "SwiftData", existing: try context.fetch(FetchDescriptor<VocabularyWord>()), context: context
        ))

        let vocabulary = CustomVocabularyService.shared.loadSavedVocabulary(from: context)
            .addingScreenNames(["Quarterly Plan"])
        let prompt = vocabulary.enhancementSection

        XCTAssertEqual(vocabulary.terms, ["SwiftData", "VoiceInk", "Quarterly Plan"])
        XCTAssertTrue(prompt.contains(VocabularySoundsLike.promptGuidance), prompt)
        XCTAssertTrue(prompt.contains(
            "Important Vocabulary:\nSwiftData\nVoiceInk (may be transcribed as voice ink, &lt;voicing&gt;)\nQuarterly Plan\n"
        ), prompt)
    }

    func testSectionedEnhancementPromptCarriesSpellingsAndGuidance() throws {
        let context = try makeContext()
        let section = VocabularySection(name: "Tech")
        context.insert(section)
        context.insert(VocabularyWord(word: "WebSocket", sectionID: section.id, soundsLike: ["web socket"]))
        try context.save()

        let prompt = CustomVocabularyService.shared.loadSavedVocabulary(from: context).enhancementSection

        XCTAssertTrue(prompt.contains(VocabularySoundsLike.promptGuidance), prompt)
        XCTAssertTrue(prompt.contains("Tech: WebSocket (may be transcribed as web socket)"), prompt)
    }

    func testPromptWithoutSpellingsIsUnchanged() {
        let vocabulary = RecordingVocabulary(savedTerms: ["VoiceInk"])

        XCTAssertEqual(vocabulary.enhancementSection, """
        Use these entries as preferred spellings for clearly matching words, names, and phonetic transcription mistakes.
        <CUSTOM_VOCABULARY>
        Important Vocabulary:
        VoiceInk
        </CUSTOM_VOCABULARY>
        """)
    }

    func testSpellingsDoNotBecomeWordReplacements() throws {
        let context = try makeContext()
        context.insert(VocabularyWord(word: "VoiceInk", soundsLike: ["voice ink"]))
        context.insert(WordReplacement(originalText: "web socket", replacementText: "WebSocket"))
        try context.save()

        let result = WordReplacementService.shared.applyReplacements(
            to: "voice ink opens a web socket", using: context
        )

        XCTAssertEqual(result, "voice ink opens a WebSocket")
    }

    // MARK: - Editing

    func testSpellingsApplyToOneNewTermAtATime() throws {
        let context = try makeContext()

        let error = DictionaryService.addVocabularyWords(
            "Swift, Kotlin", existing: [], context: context, soundsLike: "swiftly"
        )

        XCTAssertNotNil(error)
        XCTAssertTrue(try context.fetch(FetchDescriptor<VocabularyWord>()).isEmpty)
    }

    func testSectionScopedDuplicatesStillApplyWithSpellings() throws {
        let context = try makeContext()
        let section = VocabularySection(name: "Work")
        context.insert(section)
        context.insert(VocabularyWord(word: "VoiceInk"))
        try context.save()
        let existing = try context.fetch(FetchDescriptor<VocabularyWord>())

        let duplicate = DictionaryService.addVocabularyWords(
            "voiceink", existing: existing, context: context, soundsLike: "voice ink"
        )
        let otherSection = DictionaryService.addVocabularyWords(
            "VoiceInk", existing: existing, context: context, sectionID: section.id, soundsLike: "voice ink"
        )

        XCTAssertNotNil(duplicate)
        XCTAssertNil(otherSection)
        let words = try context.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(words.first { $0.sectionID == nil }?.soundsLike, [])
        XCTAssertEqual(words.first { $0.sectionID == section.id }?.soundsLike, ["voice ink"])
    }

    func testUpdatingSpellingsKeepsIdentityAndSurvivesSectionMoves() throws {
        let context = try makeContext()
        let section = VocabularySection(name: "Work")
        context.insert(section)
        let word = VocabularyWord(word: "VoiceInk")
        context.insert(word)
        try context.save()
        let identifier = word.persistentModelID

        XCTAssertNil(DictionaryService.updateVocabularySoundsLike(
            word, soundsLike: "voice ink, Voice Ink, voicing", context: context
        ))
        XCTAssertNil(VocabularySectionService.move(word, to: section.id, context: context))

        let saved = try XCTUnwrap(context.fetch(FetchDescriptor<VocabularyWord>()).first)
        XCTAssertEqual(saved.persistentModelID, identifier)
        XCTAssertEqual(saved.sectionID, section.id)
        XCTAssertEqual(saved.soundsLike, ["voice ink", "voicing"])
        XCTAssertNil(DictionaryService.updateVocabularySoundsLike(saved, soundsLike: " ", context: context))
        XCTAssertEqual(saved.soundsLikeText, "")
    }

    func testDuplicateRemovalMergesSpellingsIntoTheRetainedTerm() throws {
        let context = try makeContext()
        let section = VocabularySection(name: "Work")
        context.insert(section)
        context.insert(VocabularyWord(word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 1), soundsLike: ["voice ink"]))
        context.insert(VocabularyWord(word: "voiceink", dateAdded: Date(timeIntervalSince1970: 2), soundsLike: ["voicing"]))
        context.insert(VocabularyWord(word: "VOICEINK", sectionID: section.id, soundsLike: ["vo ink", "voice ink"]))
        try context.save()

        DictionaryService.cleanUpDictionaryContent(context: context, source: "test")
        XCTAssertNil(VocabularySectionService.delete(
            section, words: try context.fetch(FetchDescriptor<VocabularyWord>()), context: context
        ))

        let words = try context.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(words.map(\.word), ["VoiceInk"])
        XCTAssertEqual(words.first?.soundsLike, ["voice ink", "voicing", "vo ink"])
    }

    // MARK: - Persistence compatibility

    func testStoreWithoutSpellingsMigratesAndKeepsNewSpellings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("dictionary.store")
        let sectionID = UUID()
        do {
            let legacySchema = Schema(versionedSchema: DictionarySchemaV2.self)
            let legacyContainer = try ModelContainer(for: legacySchema, configurations: ModelConfiguration(
                "dictionary", schema: legacySchema, url: storeURL, cloudKitDatabase: .none
            ))
            let legacyContext = ModelContext(legacyContainer)
            legacyContext.insert(DictionarySchemaV2.VocabularySection(id: sectionID, name: "Work", sectionDescription: "Jobs"))
            legacyContext.insert(DictionarySchemaV2.VocabularyWord(
                word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 1_700_000_000), sectionID: sectionID
            ))
            legacyContext.insert(DictionarySchemaV2.WordReplacement(originalText: "web socket", replacementText: "WebSocket"))
            try legacyContext.save()
        }
        let schema = Schema([VocabularyWord.self, WordReplacement.self, VocabularySection.self])
        let open = {
            ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(
                "dictionary", schema: schema, url: storeURL, cloudKitDatabase: .none
            )))
        }

        do {
            let context = try open()
            let word = try XCTUnwrap(context.fetch(FetchDescriptor<VocabularyWord>()).first)
            XCTAssertEqual(word.word, "VoiceInk")
            XCTAssertEqual(word.sectionID, sectionID)
            XCTAssertEqual(word.dateAdded, Date(timeIntervalSince1970: 1_700_000_000))
            XCTAssertEqual(word.soundsLike, [])
            XCTAssertEqual(try context.fetch(FetchDescriptor<VocabularySection>()).first?.sectionDescription, "Jobs")
            XCTAssertEqual(try context.fetch(FetchDescriptor<WordReplacement>()).first?.replacementText, "WebSocket")
            XCTAssertNil(DictionaryService.updateVocabularySoundsLike(word, soundsLike: "voice ink", context: context))
        }

        let reopened = try open()
        XCTAssertEqual(try reopened.fetch(FetchDescriptor<VocabularyWord>()).first?.soundsLike, ["voice ink"])
    }

    func testDictionaryArchiveRoundTripsSpellingsAndOmitsEmptyOnes() async throws {
        let source = try makeContext()
        let section = VocabularySection(name: "Tech")
        source.insert(section)
        source.insert(VocabularyWord(word: "WebSocket", sectionID: section.id, soundsLike: ["web socket"]))
        source.insert(VocabularyWord(word: "Plain"))
        try source.save()

        let data = try DictionaryImportExportService.encodeArchive(
            DictionaryImportExportService.makeArchive(modelContext: source)
        )
        let archive = try DictionaryImportExportService.decodeArchiveData(data).archive
        let destination = try makeContext()
        _ = try await DictionaryImportExportService.apply(archive: archive, mode: .replace, modelContext: destination)

        XCTAssertEqual(archive.schemaVersion, 3)
        XCTAssertEqual(String(decoding: data, as: UTF8.self).components(separatedBy: "soundsLike").count, 2)
        let words = try destination.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(words.first { $0.word == "WebSocket" }?.soundsLike, ["web socket"])
        XCTAssertEqual(words.first { $0.word == "WebSocket" }?.sectionID, section.id)
        XCTAssertEqual(words.first { $0.word == "Plain" }?.soundsLike, [])
    }

    func testArchiveExportMergesDuplicateSpellingsWithoutMutatingTheStore() async throws {
        let source = try makeContext()
        let section = VocabularySection(name: "Work")
        source.insert(section)
        let words = [
            VocabularyWord(word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 1), soundsLike: ["voice ink"]),
            VocabularyWord(word: "voiceink", dateAdded: Date(timeIntervalSince1970: 2), soundsLike: ["VOICE INK", "voicing"]),
            VocabularyWord(word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 3), sectionID: section.id, soundsLike: ["work ink"]),
            VocabularyWord(word: "VOICEINK", dateAdded: Date(timeIntervalSince1970: 4), sectionID: section.id, soundsLike: ["work voice"]),
            VocabularyWord(word: "VoiceInk", dateAdded: Date(timeIntervalSince1970: 5), sectionID: UUID(), soundsLike: ["v ink"]),
        ]
        for word in words { source.insert(word) }
        try source.save()
        let originalIDs = Set(words.map(\.persistentModelID))
        let originalSpellings = words.map(\.soundsLike)

        let data = try DictionaryImportExportService.encodeArchive(
            DictionaryImportExportService.makeArchive(modelContext: source)
        )
        let archive = try DictionaryImportExportService.decodeArchiveData(data).archive
        let destination = try makeContext()
        _ = try await DictionaryImportExportService.apply(archive: archive, mode: .replace, modelContext: destination)

        let restored = try destination.fetch(FetchDescriptor<VocabularyWord>())
        XCTAssertEqual(restored.count, 2)
        let unsectioned = try XCTUnwrap(restored.first { $0.sectionID == nil })
        XCTAssertEqual(unsectioned.word, "VoiceInk")
        XCTAssertEqual(unsectioned.dateAdded, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(unsectioned.soundsLike, ["voice ink", "voicing", "v ink"])
        let sectioned = try XCTUnwrap(restored.first { $0.sectionID == section.id })
        XCTAssertEqual(sectioned.word, "VoiceInk")
        XCTAssertEqual(sectioned.dateAdded, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(sectioned.soundsLike, ["work ink", "work voice"])
        XCTAssertEqual(Set(try source.fetch(FetchDescriptor<VocabularyWord>()).map(\.persistentModelID)), originalIDs)
        XCTAssertEqual(words.map(\.soundsLike), originalSpellings)
        XCTAssertFalse(source.hasChanges)
    }

    func testLegacyArchivesImportWithoutSpellings() async throws {
        let sectionID = UUID().uuidString
        let archives = [
            #"{"format":"voiceink.dictionary","schemaVersion":1,"exportedAt":"2024-01-01T00:00:00Z","vocabulary":[{"term":"VoiceInk","createdAt":"2024-01-01T00:00:00Z"}],"replacements":[{"sources":["web socket"],"replacement":"WebSocket","createdAt":null}]}"#,
            #"{"format":"voiceink.dictionary","schemaVersion":2,"exportedAt":"2024-01-01T00:00:00Z","vocabulary":[{"term":"VoiceInk","sectionID":"\#(sectionID)"}],"replacements":[],"sections":[{"id":"\#(sectionID)","name":"Work","description":""}]}"#,
        ]

        for json in archives {
            let context = try makeContext()
            let archive = try DictionaryImportExportService.decodeArchiveData(Data(json.utf8)).archive

            _ = try await DictionaryImportExportService.apply(archive: archive, mode: .merge, modelContext: context)

            let word = try XCTUnwrap(context.fetch(FetchDescriptor<VocabularyWord>()).first, json)
            XCTAssertEqual(word.word, "VoiceInk")
            XCTAssertEqual(word.soundsLike, [])
        }
    }

    func testArchiveImportKeepsTheSpellingsThatFit() async throws {
        let context = try makeContext()
        let archive = DictionaryArchive(
            vocabulary: [DictionaryVocabularyEntry(
                term: "Term", createdAt: nil,
                soundsLike: ["term", "a, b"] + (1...20).map { "s\($0)" }
            )],
            replacements: []
        )

        _ = try await DictionaryImportExportService.apply(archive: archive, mode: .merge, modelContext: context)

        let word = try XCTUnwrap(context.fetch(FetchDescriptor<VocabularyWord>()).first)
        XCTAssertEqual(word.soundsLike, ["a", "b"] + (1...14).map { "s\($0)" })
    }

    func testBackupWordsDecodeWithAndWithoutSpellings() throws {
        let legacy = try JSONDecoder().decode(WordBackup.self, from: Data(#"{"word":"VoiceInk"}"#.utf8))
        let current = try JSONDecoder().decode(
            WordBackup.self, from: JSONEncoder().encode(WordBackup(word: "VoiceInk", soundsLike: ["voice ink"]))
        )
        let empty = String(decoding: try JSONEncoder().encode(WordBackup(word: "VoiceInk")), as: UTF8.self)

        XCTAssertNil(legacy.soundsLike)
        XCTAssertEqual(current.soundsLike, ["voice ink"])
        XCTAssertFalse(empty.contains("soundsLike"))
    }
}
