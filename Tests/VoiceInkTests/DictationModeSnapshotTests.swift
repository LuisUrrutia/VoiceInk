import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

@MainActor
final class DictationModeSnapshotTests: XCTestCase {
    private let activeConfigurationKey = "activeConfigurationId"
    private var originalConfigurations: [ModeConfig] = []
    private var originalActiveConfiguration: ModeConfig?
    private var originalActiveConfigurationID: Any?

    override func setUp() async throws {
        let manager = ModeManager.shared
        originalConfigurations = manager.configurations
        originalActiveConfiguration = manager.activeConfiguration
        originalActiveConfigurationID = UserDefaults.standard.object(forKey: activeConfigurationKey)
    }

    override func tearDown() async throws {
        let manager = ModeManager.shared
        manager.configurations = originalConfigurations
        manager.activeConfiguration = originalActiveConfiguration
        UserDefaults.standard.set(originalActiveConfigurationID, forKey: activeConfigurationKey)
    }

    func testModeChangesDuringTranscriptionAndEnhancementDoNotReachTheDictation() async throws {
        let dictationMode = ModeConfig(
            name: "Dictation", isAIEnhancementEnabled: true, isTextFormattingEnabled: true, autoSendKey: .none
        )
        let laterMode = ModeConfig(name: "Later", isAIEnhancementEnabled: false, autoSendKey: .enter)
        let manager = ModeManager.shared
        manager.configurations = [dictationMode, laterMode]
        manager.activeConfiguration = dictationMode
        let resolved = DictationModeSnapshot.resolve(modeID: dictationMode.id, enhancementService: nil)
        // A production enhancement configuration needs a live AIEnhancementService, which repairs persisted modes.
        let snapshot = DictationModeSnapshot(
            mode: resolved.mode, formatting: resolved.formatting,
            enhancement: EnhancementRuntimeConfiguration(
                mode: dictationMode, isEnabled: true, prompt: nil, provider: .ollama, modelName: "fixture",
                useClipboardContext: false, useSelectedTextContext: false, useScreenCaptureContext: false
            ),
            output: resolved.output
        )
        let fixture = try PipelineFixture(transcript: Self.multiSentenceTranscript)
        XCTAssertNotEqual(ParagraphFormatter.format(Self.multiSentenceTranscript), Self.multiSentenceTranscript)

        let run = Task { await fixture.run(mode: dictationMode, snapshot: snapshot) }
        await fulfillment(of: [fixture.session.entered], timeout: 3)
        manager.activeConfiguration = laterMode
        fixture.session.release()
        await fulfillment(of: [fixture.enhancer.entered], timeout: 3)
        var editedDictationMode = dictationMode
        editedDictationMode.autoSendKey = .commandEnter
        manager.configurations = [editedDictationMode, laterMode]
        fixture.enhancer.release()
        let transcription = await run.value

        XCTAssertEqual(fixture.enhancer.configurations.map { $0.mode?.id }, [dictationMode.id])
        XCTAssertEqual(fixture.enhancer.inputs, [ParagraphFormatter.format(Self.multiSentenceTranscript)])
        XCTAssertEqual(fixture.pastes.map(\.text), ["Enhanced dictation text"])
        XCTAssertEqual(fixture.pastes.map(\.sendKey), [.none])
        XCTAssertEqual(transcription.modeName, "Dictation")
        XCTAssertEqual(transcription.transcriptionStatus, TranscriptionStatus.completed.rawValue)
    }

    func testTriggerWordInThePipelineChangesOnlyItsDictation() async throws {
        let speakingMode = ModeConfig(name: "Speaking", isAIEnhancementEnabled: false, isDefault: true)
        let triggeredMode = ModeConfig(
            name: "Triggered", triggerWords: ["beta"], isAIEnhancementEnabled: false, autoSendKey: .enter
        )
        let manager = ModeManager.shared
        manager.configurations = [speakingMode, triggeredMode]
        manager.activeConfiguration = speakingMode
        let capture = try await startCapture(lookupModeID: speakingMode.id)
        let fixture = try PipelineFixture(transcript: "Beta send the report")
        fixture.session.release()

        let transcription = await fixture.run(
            mode: speakingMode,
            snapshot: DictationModeSnapshot.resolve(mode: speakingMode, enhancementService: nil),
            triggerWordModeSelection: { DictationModeSnapshot.triggerWordSelection(in: $0, enhancementService: nil) }
        )
        capture.freezeModeSelection()

        XCTAssertEqual(fixture.pastes.map(\.text), ["Send the report"])
        XCTAssertEqual(fixture.pastes.map(\.sendKey), [.enter])
        XCTAssertEqual(transcription.modeName, "Triggered")
        XCTAssertEqual(manager.currentEffectiveConfiguration?.id, triggeredMode.id)
        XCTAssertEqual(capture.modeSnapshot?.mode?.id, speakingMode.id)
        XCTAssertEqual(capture.modeSnapshot?.output.autoSendKey, FinishAndSendKey.none)
    }

    func testPendingLookupResolvesWithStopTimeSettings() async throws {
        let fallback = ModeConfig(name: "Fallback", isAIEnhancementEnabled: false, isDefault: true)
        var website = ModeConfig(name: "Website", isAIEnhancementEnabled: false)
        let manager = ModeManager.shared
        manager.configurations = [fallback, website]
        manager.activeConfiguration = fallback
        let lookup = ReleaseGate()
        var resolvedConfigurationModes: [ModeConfig?] = []
        let capture = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        let websiteID = website.id
        capture.ownModeResolution(Task { await lookup.wait(); return websiteID })
        capture.start(
            resolveModeSnapshot: { DictationModeSnapshot.resolve(modeID: $0 ?? fallback.id, enhancementService: nil) },
            freezeModeSnapshots: {
                DictationModeSnapshot.frozenResolver(fallbackModeID: fallback.id, enhancementService: nil)
            },
            resolveConfiguration: { resolvedConfigurationModes.append($0?.mode); return nil },
            retireAutoLearn: {}, prepareModel: { _ in }, prepareSession: { _ in nil }
        )

        website.autoSendKey = .enter
        manager.configurations = [fallback, website]
        capture.freezeModeSelection()
        website.autoSendKey = .commandEnter
        website.isTextFormattingEnabled = true
        manager.configurations = [fallback, website]
        lookup.release()
        _ = try await capture.setup()

        XCTAssertEqual(capture.modeSnapshot?.mode?.id, website.id)
        XCTAssertEqual(capture.modeSnapshot?.output.autoSendKey, .enter)
        XCTAssertEqual(capture.modeSnapshot?.formatting.isTextFormattingEnabled, false)
        XCTAssertEqual(resolvedConfigurationModes.map { $0?.autoSendKey }, [.enter])
    }

    private static let multiSentenceTranscript = """
        The first quarter closed with steady growth across every region we track. Our team shipped \
        three releases and fixed most of the reported crashes. Support volume dropped after the onboarding \
        changes went live. Hiring stayed slower than planned because two offers were declined. The budget for \
        the next quarter still needs approval from finance. We will review the roadmap together on Friday \
        morning.
        """

    func testEarlierBrowserLookupSurvivesALaterLookupRequest() async {
        let fixture = LookupFixture()

        let earlier = fixture.service.beginApplyingConfiguration()
        await fixture.waitForLookups(1)
        let later = fixture.service.beginApplyingConfiguration()
        await fixture.waitForLookups(2)
        fixture.complete(lookup: 1, with: "https://later.invalid/page")
        let laterModeID = await later.value
        fixture.complete(lookup: 0, with: "https://earlier.invalid/page")
        let earlierModeID = await earlier.value

        XCTAssertEqual(earlierModeID, fixture.earlierSite.id)
        XCTAssertEqual(laterModeID, fixture.laterSite.id)
        XCTAssertEqual(fixture.applied.map(\.id), [fixture.fallback.id, fixture.fallback.id, fixture.laterSite.id])
    }

    func testTriggerWordLeavesARunningCaptureUnchangedAndSetsTheGlobalMode() async throws {
        let captureMode = ModeConfig(name: "Capture", isAIEnhancementEnabled: false, isDefault: true)
        let triggeredMode = ModeConfig(name: "Triggered", triggerWords: ["beta"], isAIEnhancementEnabled: false)
        let manager = ModeManager.shared
        manager.configurations = [captureMode, triggeredMode]
        manager.activeConfiguration = captureMode
        let capture = try await startCapture(lookupModeID: captureMode.id)

        let selection = DictationModeSnapshot.triggerWordSelection(
            in: "Beta hello there", enhancementService: nil
        )
        capture.freezeModeSelection()

        XCTAssertEqual(selection?.text, "Hello there")
        XCTAssertEqual(selection?.modeSnapshot.mode?.id, triggeredMode.id)
        XCTAssertEqual(manager.currentEffectiveConfiguration?.id, triggeredMode.id)
        XCTAssertEqual(capture.modeSnapshot?.mode?.id, captureMode.id)
        XCTAssertEqual(capture.modeSnapshot?.metadata.name, "Capture")
    }

    func testSelectionDuringCaptureReachesItAtStopButNotAfterwards() async throws {
        let captureMode = ModeConfig(name: "Capture", isAIEnhancementEnabled: false, isDefault: true)
        let selectedMode = ModeConfig(name: "Selected", isAIEnhancementEnabled: false, autoSendKey: .enter)
        let laterMode = ModeConfig(name: "Later", isAIEnhancementEnabled: false)
        let manager = ModeManager.shared
        manager.configurations = [captureMode, selectedMode, laterMode]
        manager.activeConfiguration = captureMode
        let capture = try await startCapture(lookupModeID: captureMode.id)

        manager.setActiveConfiguration(selectedMode)
        capture.freezeModeSelection()
        manager.setActiveConfiguration(laterMode)
        capture.freezeModeSelection()

        XCTAssertEqual(capture.modeSnapshot?.mode?.id, selectedMode.id)
        XCTAssertEqual(capture.modeSnapshot?.output.autoSendKey, .enter)
        XCTAssertEqual(capture.selectedModeID, selectedMode.id)
    }

    /// Mirrors the engine's capture start: the lookup's own apply happens before the selection baseline.
    private func startCapture(lookupModeID: UUID) async throws -> RecordingTranscriptionPreparation {
        let manager = ModeManager.shared
        let generation = manager.selectionGeneration
        let capture = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        capture.ownModeResolution(Task { lookupModeID })
        capture.start(
            resolveModeSnapshot: { DictationModeSnapshot.resolve(modeID: $0, enhancementService: nil) },
            userModeSelection: { manager.selectedConfigurationID(since: generation) },
            resolveConfiguration: { _ in nil }, retireAutoLearn: {}, prepareModel: { _ in },
            prepareSession: { _ in nil }
        )
        _ = try await capture.setup()
        return capture
    }
}

@MainActor
private final class PipelineFixture {
    let directory: URL
    let container: ModelContainer
    let context: ModelContext
    let session: HeldTranscriptionSession
    let enhancer = HeldEnhancer(text: "Enhanced dictation text")
    private(set) var pastes: [(text: String, sendKey: FinishAndSendKey)] = []
    private(set) var pipeline: TranscriptionPipeline!

    init(transcript: String) throws {
        session = HeldTranscriptionSession(text: transcript)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".tmp/dictation-mode-snapshot-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The app's store layout: a completed dictation also records its session metric.
        container = try ModelContainer(
            for: Schema([Transcription.self, VocabularyWord.self, WordReplacement.self, SessionMetric.self, VocabularySection.self]),
            configurations:
                ModelConfiguration("default", schema: Schema([Transcription.self]), isStoredInMemoryOnly: true),
                ModelConfiguration(
                    "dictionary", schema: Schema([VocabularyWord.self, WordReplacement.self, VocabularySection.self]),
                    isStoredInMemoryOnly: true
                ),
                ModelConfiguration("stats", schema: Schema([SessionMetric.self]), isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        pipeline = TranscriptionPipeline(
            modelContext: context,
            serviceRegistry: TranscriptionServiceRegistry(
                modelProvider: whisper, modelsDirectory: directory, modelContext: context
            ),
            enhancementService: enhancer,
            delivery: TranscriptionDelivery(startPaste: { [weak self] text, _, sendKey in
                self?.pastes.append((text.trimmingCharacters(in: .whitespaces), sendKey))
                return Task { CursorPaster.PasteOutcome(result: .commandPosted, autoLearnGeneration: nil, target: nil) }
            })
        )
    }

    func run(
        mode: ModeConfig, snapshot: DictationModeSnapshot,
        triggerWordModeSelection: (String) -> (text: String, modeSnapshot: DictationModeSnapshot)? = { _ in nil }
    ) async -> Transcription {
        let transcription = Transcription(text: "", duration: 0, transcriptionStatus: .pending)
        context.insert(transcription)
        await pipeline.run(
            transcription: transcription,
            audioURL: directory.appendingPathComponent("missing.wav"),
            transcriptionConfiguration: TranscriptionRuntimeConfiguration(
                mode: mode, model: ImportedWhisperModel(fileBaseName: "ggml-small"),
                languages: ["en"], isRealtimeEnabled: true
            ),
            modeSnapshot: snapshot,
            session: session,
            triggerWordModeSelection: triggerWordModeSelection,
            vocabularyPreparation: RecordingVocabularyPreparation(savedVocabulary: RecordingVocabulary()),
            onStateChange: { _ in }, shouldCancel: { false }, onCancel: {}, onDismiss: {}
        )
        return transcription
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class ReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HeldTranscriptionSession: TranscriptionSession {
    let entered = XCTestExpectation(description: "transcription entered")
    private let text: String
    private let gate = ReleaseGate()

    init(text: String) { self.text = text }

    func prepare(
        configuration: TranscriptionRuntimeConfiguration, vocabulary: RecordingVocabulary
    ) async throws -> ((Data) -> Void)? { nil }

    func transcribe(audioURL: URL, vocabulary: RecordingVocabulary) async throws -> String {
        entered.fulfill()
        await gate.wait()
        return text
    }

    func release() { gate.release() }
    func cancel() { gate.release() }
}

@MainActor
private final class HeldEnhancer: DictationEnhancing {
    let entered = XCTestExpectation(description: "enhancement entered")
    private(set) var configurations: [EnhancementRuntimeConfiguration] = []
    private(set) var inputs: [String] = []
    private let text: String
    private let gate = ReleaseGate()

    init(text: String) { self.text = text }

    func isConfigured(for configuration: EnhancementRuntimeConfiguration) -> Bool { true }

    func enhance(
        _ text: String, configuration: EnhancementRuntimeConfiguration,
        contextSnapshot: RecordingContextSnapshot?, vocabulary: RecordingVocabulary?
    ) async throws -> AIEnhancementResult {
        configurations.append(configuration)
        inputs.append(text)
        entered.fulfill()
        await gate.wait()
        return AIEnhancementResult(
            text: self.text, duration: 0, promptName: nil, systemMessage: nil, userMessage: nil
        )
    }

    func release() { gate.release() }
}

@MainActor
private final class LookupFixture {
    let fallback = ModeConfig(name: "Default", isAIEnhancementEnabled: false, isDefault: true)
    let earlierSite = ModeConfig(name: "Earlier", urlConfigs: [.init(url: "earlier.invalid")], isAIEnhancementEnabled: false)
    let laterSite = ModeConfig(name: "Later", urlConfigs: [.init(url: "later.invalid")], isAIEnhancementEnabled: false)
    private(set) var applied: [ModeConfig] = []
    private var lookups: [CheckedContinuation<String, Error>] = []
    private var lookupWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    lazy var service = ActiveWindowService(
        frontmostApplication: { .init(bundleIdentifier: BrowserType.safari.bundleIdentifier) },
        configurations: { [unowned self] in [self.fallback, self.earlierSite, self.laterSite] },
        apply: { [unowned self] in self.applied.append($0) },
        currentURL: { [unowned self] _ in try await self.pendingLookup() }
    )

    private func pendingLookup() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            lookups.append(continuation)
            resumeLookupWaiters()
        }
    }

    func waitForLookups(_ count: Int) async {
        guard lookups.count < count else { return }
        await withCheckedContinuation { lookupWaiters.append((count, $0)) }
    }

    func complete(lookup index: Int, with url: String) {
        lookups[index].resume(returning: url)
    }

    private func resumeLookupWaiters() {
        let ready = lookupWaiters.filter { $0.count <= lookups.count }
        lookupWaiters.removeAll { $0.count <= lookups.count }
        ready.forEach { $0.continuation.resume() }
    }
}
