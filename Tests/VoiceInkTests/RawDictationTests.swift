import Carbon
import SwiftData
import XCTest
@testable import VoiceInk

/// The History store schema before raw dictations were marked.
private enum HistorySchemaBeforeRawDictation: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] { [Transcription.self] }

    @Model
    final class Transcription {
        #Index<Transcription>([\.timestamp, \.id])

        var id: UUID = UUID()
        var text: String = ""
        var enhancedText: String?
        @Attribute(hashModifier: "historyCompositeIndex")
        var timestamp: Date = Date()
        var duration: TimeInterval = 0
        var audioFileURL: String?
        var transcriptionModelName: String?
        var aiEnhancementModelName: String?
        var promptName: String?
        var transcriptionDuration: TimeInterval?
        var enhancementDuration: TimeInterval?
        var aiRequestSystemMessage: String?
        var aiRequestUserMessage: String?
        @Attribute(originalName: "powerModeName")
        var modeName: String?
        @Attribute(originalName: "powerModeEmoji")
        var modeEmoji: String?
        var transcriptionStatus: String?

        init(id: UUID, text: String, enhancedText: String?, timestamp: Date, modeName: String?) {
            self.id = id
            self.text = text
            self.enhancedText = enhancedText
            self.timestamp = timestamp
            self.modeName = modeName
            self.transcriptionStatus = "completed"
        }
    }
}

@MainActor
final class RawDictationTests: XCTestCase {
    // MARK: - Shortcut ownership

    func testRawShortcutStartsARawCaptureThatOnlyItCanFinish() async {
        let fixture = OwnershipFixture()

        await fixture.press(.rawRecording, at: 0, mode: .toggle)
        await fixture.press(.primaryRecording, at: 1, mode: .toggle)
        await fixture.press(.secondaryRecording, at: 2, mode: .toggle)
        XCTAssertEqual(fixture.toggles, [.raw])
        XCTAssertEqual(fixture.owner, .raw)

        await fixture.press(.rawRecording, at: 3, mode: .toggle)

        XCTAssertEqual(fixture.toggles, [.raw, .raw])
        XCTAssertNil(fixture.owner)
    }

    func testNormalCaptureIgnoresTheRawShortcutUntilItFinishes() async {
        let fixture = OwnershipFixture()

        await fixture.press(.primaryRecording, at: 0, mode: .pushToTalk, release: 1)
        XCTAssertEqual(fixture.owner, nil)
        await fixture.press(.primaryRecording, at: 2, mode: .toggle)
        await fixture.press(.rawRecording, at: 3, mode: .toggle)
        XCTAssertEqual(fixture.owner, .standard)

        await fixture.press(.primaryRecording, at: 4, mode: .toggle)
        await fixture.press(.rawRecording, at: 5, mode: .toggle)

        XCTAssertEqual(fixture.toggles, [.standard, .standard, .standard, .standard, .raw])
        XCTAssertEqual(fixture.owner, .raw)
    }

    func testOtherShortcutTapsNeitherFinishNorCountTowardADoubleTap() async {
        let fixture = OwnershipFixture()
        await fixture.press(.rawRecording, at: 0, mode: .doubleTap, release: 0.05)
        await fixture.press(.rawRecording, at: 0.1, mode: .doubleTap, release: 0.15)
        XCTAssertEqual(fixture.owner, .raw)

        await fixture.press(.primaryRecording, at: 1, mode: .doubleTap, release: 1.05)
        await fixture.press(.primaryRecording, at: 1.1, mode: .doubleTap, release: 1.15)
        await fixture.press(.rawRecording, at: 1.2, mode: .doubleTap, release: 1.25)
        XCTAssertEqual(fixture.toggles, [.raw])
        await fixture.press(.rawRecording, at: 1.3, mode: .doubleTap, release: 1.35)

        XCTAssertEqual(fixture.toggles, [.raw, .raw])
        XCTAssertNil(fixture.owner)
    }

    func testRawHoldDuringAHandsFreeCaptureDoesNotStopItOnRelease() async {
        let fixture = OwnershipFixture()
        await fixture.press(.primaryRecording, at: 0, mode: .toggle)

        await fixture.press(.rawRecording, at: 1, mode: .pushToTalk, release: 2)

        XCTAssertEqual(fixture.toggles, [.standard])
        XCTAssertEqual(fixture.owner, .standard)
        await fixture.press(.primaryRecording, at: 3, mode: .toggle)
        XCTAssertEqual(fixture.toggles, [.standard, .standard])
    }

    func testRawShortcutUsesThePrimaryModeForChordHandling() {
        for primary in RecordingShortcutManager.Mode.allCases {
            let delays = RecordingShortcutManager.chordBreakerDelays(primaryMode: primary, secondaryMode: .pushToTalk)
            let standalone = RecordingShortcutManager.standaloneModifierActions(primaryMode: primary, secondaryMode: .hybrid)

            XCTAssertEqual(delays[.rawRecording], delays[.primaryRecording], "\(primary)")
            XCTAssertEqual(standalone.contains(.rawRecording), standalone.contains(.primaryRecording), "\(primary)")
        }
    }

    // MARK: - Shortcut storage

    func testRawShortcutIsUnboundByDefaultAndConflictsWithOtherBindings() throws {
        let defaults = StoredShortcuts([.rawRecording, .primaryRecording])
        defer { defaults.restore() }
        XCTAssertNil(ShortcutStore.shortcut(for: .rawRecording))
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_F18), modifierFlags: [])
        ShortcutStore.setShortcut(shortcut, for: .primaryRecording)

        XCTAssertEqual(
            ShortcutValidator.validationError(for: shortcut, action: .rawRecording),
            .alreadyUsedBy(ShortcutAction.primaryRecording.displayName)
        )
        ShortcutStore.setShortcut(shortcut, for: .rawRecording)
        XCTAssertNil(ShortcutStore.shortcut(for: .rawRecording))
        XCTAssertNotNil(ShortcutValidator.validationError(
            for: .key(keyCode: UInt16(kVK_ANSI_1), modifierFlags: [.option]), action: .rawRecording
        ))
    }

    func testConfigurationCapturesValidatesAndAppliesTheRawBinding() throws {
        let suite = "RawDictationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ShortcutAction.rawRecording.userDefaultsKey
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_F18), modifierFlags: [])
        defaults.set(try JSONEncoder().encode(shortcut), forKey: key)

        let captured = try ConfigurationPreferences.capture(from: defaults)

        XCTAssertEqual(captured[key], try .encoded(shortcut))
        let primary = ShortcutAction.primaryRecording.userDefaultsKey
        XCTAssertThrowsError(try ConfigurationPreferences.validate([primary: try .encoded(shortcut)], defaults: defaults))
        XCTAssertThrowsError(try ConfigurationPreferences.validate(
            [key: try .encoded(Shortcut.key(keyCode: UInt16(kVK_ANSI_A), modifierFlags: []))], defaults: defaults
        ))
        let cleared: [String: ConfigurationValue] = [key: .null, "\(key)_cleared": .bool(true)]
        XCTAssertNoThrow(try ConfigurationPreferences.validate(cleared, defaults: defaults))
        try ConfigurationPreferences.apply(cleared, to: defaults)
        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertTrue(defaults.bool(forKey: "\(key)_cleared"))
    }

    func testBackupRestoresBindingAndUnboundStateAndKeepsTheCurrentBindingWhenMissing() throws {
        let defaults = StoredShortcuts([.rawRecording])
        defer { defaults.restore() }
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_F17), modifierFlags: [])
        let bound = try decodeBackup(["rawRecordingShortcut": try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ShortcutBackup(shortcut))
        )])

        bound.restoreRawRecordingShortcut()
        XCTAssertEqual(ShortcutStore.shortcut(for: .rawRecording), shortcut)
        try decodeBackup([:]).restoreRawRecordingShortcut()
        XCTAssertEqual(ShortcutStore.shortcut(for: .rawRecording), shortcut)
        try decodeBackup(["isRawRecordingShortcutUnbound": true]).restoreRawRecordingShortcut()

        XCTAssertNil(ShortcutStore.shortcut(for: .rawRecording))
    }

    // MARK: - Pipeline

    func testRawDictationPastesTheTrimmedTranscriptWithoutProcessing() async throws {
        let run = try await PipelineRun(rawText: "  um, teh <NOTE>aside</NOTE> plan  ", isRaw: true)

        XCTAssertEqual(run.transcription.text, "um, teh <NOTE>aside</NOTE> plan")
        XCTAssertEqual(run.pastes.map(\.text), ["um, teh <NOTE>aside</NOTE> plan" + run.trailingSpace])
        XCTAssertEqual(run.pastes.map(\.sendKey), [FinishAndSendKey.none])
        XCTAssertNil(run.transcription.enhancedText)
        XCTAssertEqual(run.transcription.transcriptionStatus, TranscriptionStatus.completed.rawValue)
        XCTAssertEqual(run.triggerWordChecks, 0)
    }

    func testStandardDictationStillCleansAndReplaces() async throws {
        let run = try await PipelineRun(rawText: "  teh <NOTE>aside</NOTE> plan  ", isRaw: false)

        XCTAssertEqual(run.transcription.text, "the plan")
        XCTAssertEqual(run.pastes.map(\.text), ["the plan" + run.trailingSpace])
        XCTAssertEqual(run.pastes.map(\.sendKey), [FinishAndSendKey.enter])
        XCTAssertEqual(run.triggerWordChecks, 1)
    }

    // MARK: - History

    func testRawEntryIsTheLastDictationAndPastesItsText() throws {
        let schema = Schema([Transcription.self])
        let context = ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ))
        let older = Transcription(text: "Older", duration: 1, transcriptionStatus: .completed)
        older.timestamp = Date(timeIntervalSince1970: 1)
        let raw = Transcription(text: "um raw text", duration: 1, transcriptionStatus: .completed, isRawDictation: true)
        context.insert(older)
        context.insert(raw)
        try context.save()

        let last = try XCTUnwrap(LastTranscriptionService.getLastTranscription(from: context))

        XCTAssertTrue(last.isRawDictation)
        XCTAssertEqual(last.text, "um raw text")
        XCTAssertNil(last.enhancedText)
    }

    func testStoreFromThePreviousSchemaMigratesAndPersistsRawMarks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("default.store")
        let ids = (0..<3).map { _ in UUID() }
        let tie = Date(timeIntervalSince1970: 1_700_000_000)
        try {
            let schema = Schema(versionedSchema: HistorySchemaBeforeRawDictation.self)
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration("default", schema: schema, url: storeURL, cloudKitDatabase: .none)
            )
            let context = ModelContext(container)
            for (index, id) in ids.enumerated() {
                context.insert(HistorySchemaBeforeRawDictation.Transcription(
                    id: id, text: "Text \(index)", enhancedText: index == 1 ? "Enhanced" : nil,
                    timestamp: tie, modeName: "Mode \(index)"
                ))
            }
            try context.save()
        }()

        let migrated = try openCurrentStore(at: storeURL)
        let records = try migrated.fetch(FetchDescriptor<Transcription>(sortBy: [SortDescriptor(\.text)]))
        XCTAssertEqual(records.map(\.id), ids)
        XCTAssertEqual(records.map(\.text), ["Text 0", "Text 1", "Text 2"])
        XCTAssertEqual(records.map(\.enhancedText), [nil, "Enhanced", nil])
        XCTAssertEqual(records.map(\.modeName), ["Mode 0", "Mode 1", "Mode 2"])
        XCTAssertTrue(records.allSatisfy { $0.timestamp == tie && !$0.isRawDictation })
        records[2].isRawDictation = true
        try migrated.save()

        let reopened = try openCurrentStore(at: storeURL)
        let raw = try reopened.fetch(FetchDescriptor<Transcription>(predicate: #Predicate { $0.isRawDictation }))

        XCTAssertEqual(raw.map(\.id), [ids[2]])
    }

    // MARK: - Helpers

    private func openCurrentStore(at url: URL) throws -> ModelContext {
        let schema = Schema([Transcription.self])
        return ModelContext(try ModelContainer(
            for: schema, configurations: ModelConfiguration("default", schema: schema, url: url, cloudKitDatabase: .none)
        ))
    }

    private func decodeBackup(_ fields: [String: Any]) throws -> GeneralBackup {
        try JSONDecoder().decode(GeneralBackup.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    @MainActor private final class OwnershipFixture {
        var now: TimeInterval = 0
        var owner: DictationProcessing?
        var toggles: [DictationProcessing] = []
        var held = Set<ShortcutAction>()
        lazy var handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { self.owner != nil },
            recordingState: { self.owner != nil ? .recording : .idle },
            isShortcutHeld: { self.held.contains($0) }, finishHeldRecording: {},
            toggleRecorderPanel: { _, _, processing in
                self.toggles.append(processing)
                self.owner = self.owner == nil ? processing : nil
            },
            captureProcessing: { self.owner },
            cancelRecording: { self.owner = nil },
            now: { self.now }
        )

        func press(
            _ action: ShortcutAction, at time: TimeInterval, mode: RecordingShortcutManager.Mode,
            release: TimeInterval? = nil
        ) async {
            now = time
            held.insert(action)
            await handler.handleShortcutDown(action: action, eventTime: time, mode: mode)
            // Without an explicit release, a push-to-talk press stays held.
            if let release {
                await self.release(action, at: release, mode: mode)
            } else if mode != .pushToTalk {
                await self.release(action, at: time + 0.01, mode: mode)
            }
        }

        func release(_ action: ShortcutAction, at time: TimeInterval, mode: RecordingShortcutManager.Mode) async {
            now = time
            held.remove(action)
            await handler.handleShortcutUp(action: action, eventTime: time, mode: mode)
        }
    }

    private struct StoredShortcuts {
        private let saved: [(String, Any?)]

        init(_ actions: [ShortcutAction]) {
            let keys = actions.flatMap { [$0.userDefaultsKey, "\($0.userDefaultsKey)_cleared"] }
            saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
            keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }

        func restore() {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
    }

    @MainActor private final class PipelineRun {
        private(set) var transcription: Transcription
        private(set) var pastes: [(text: String, sendKey: FinishAndSendKey)] = []
        private(set) var triggerWordChecks = 0
        let trailingSpace = UserDefaults.standard.bool(forKey: "AppendTrailingSpace") ? " " : ""

        init(rawText: String, isRaw: Bool) async throws {
            let schema = Schema([Transcription.self, WordReplacement.self, SessionMetric.self])
            let container = try ModelContainer(
                for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            )
            let context = ModelContext(container)
            context.insert(WordReplacement(originalText: "teh", replacementText: "the"))
            transcription = Transcription(text: "", duration: 0, isRawDictation: isRaw)
            context.insert(transcription)
            try context.save()
            let whisper = WhisperModelManager(modelsDirectory: URL(fileURLWithPath: "/unused-models"))
            let registry = TranscriptionServiceRegistry(
                modelProvider: whisper, modelsDirectory: whisper.modelsDirectory, modelContext: context
            )
            let delivery = TranscriptionDelivery { [weak self] text, _, sendKey in
                self?.pastes.append((text, sendKey))
                return Task { CursorPaster.PasteOutcome(result: .commandPosted, autoLearnGeneration: nil, target: nil) }
            }
            let pipeline = TranscriptionPipeline(
                modelContext: context, serviceRegistry: registry, enhancementService: nil, delivery: delivery
            )
            let mode = ModeConfig(name: "Raw fixture", isAIEnhancementEnabled: false)

            let snapshot = DictationModeSnapshot(
                mode: mode,
                formatting: TranscriptionFormattingConfiguration(mode: mode, isTextFormattingEnabled: false),
                enhancement: nil,
                output: OutputRuntimeConfiguration(mode: mode, outputMode: .paste, autoSendKey: .enter, customCommand: nil)
            )

            await pipeline.run(
                transcription: transcription,
                audioURL: URL(fileURLWithPath: "/nonexistent/raw.wav"),
                transcriptionConfiguration: TranscriptionRuntimeConfiguration(
                    mode: mode, model: ImportedWhisperModel(fileBaseName: "ggml-small"), languages: ["en"],
                    isRealtimeEnabled: false
                ),
                modeSnapshot: snapshot,
                session: FixedTextSession(text: rawText),
                triggerWordModeSelection: { [weak self] _ in
                    self?.triggerWordChecks += 1
                    return nil
                },
                vocabularyPreparation: RecordingVocabularyPreparation(savedVocabulary: RecordingVocabulary(savedTerms: [])),
                onStateChange: { _ in },
                shouldCancel: { false },
                onCancel: {},
                onDismiss: {}
            )
        }
    }

    @MainActor private final class FixedTextSession: TranscriptionSession {
        let text: String
        init(text: String) { self.text = text }
        func prepare(configuration: TranscriptionRuntimeConfiguration, vocabulary: RecordingVocabulary) async throws -> ((Data) -> Void)? { nil }
        func transcribe(audioURL: URL, vocabulary: RecordingVocabulary) async throws -> String { text }
        func cancel() {}
    }
}
