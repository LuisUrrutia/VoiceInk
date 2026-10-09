import XCTest
import SwiftData
import os
@testable import VoiceInk

@MainActor
final class RecordingTranscriptionPreparationTests: XCTestCase {
    func testPendingModeDoesNotPrepareProvisionalModelAndStopRetainsFinalConfiguration() async throws {
        let modeGate = PreparationGate()
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var configuration = makeConfiguration(languages: ["en"])
        var prepared: [TranscriptionRuntimeConfiguration] = []
        let preparedExpectation = expectation(description: "final model prepared")
        owner.ownModeResolution(Task { await modeGate.wait() })
        owner.start(
            resolveConfiguration: { configuration }, retireAutoLearn: {},
            prepareModel: { prepared.append($0); preparedExpectation.fulfill() }, prepareSession: { _ in nil }
        )
        await modeGate.waitUntilEntered()
        XCTAssertTrue(prepared.isEmpty)

        let stoppedOwner = owner
        configuration = makeConfiguration(languages: ["es", "en"], modelName: "ggml-medium")
        modeGate.open()
        let stoppedSetup = try await stoppedOwner.setup()
        let setup = try XCTUnwrap(stoppedSetup)
        await fulfillment(of: [preparedExpectation], timeout: 3)
        await stoppedOwner.waitUntilPrepared()
        configuration = makeConfiguration(languages: ["fr"])

        XCTAssertEqual(setup.configuration.model.name, "ggml-medium")
        XCTAssertEqual(setup.configuration.languages, ["es", "en"])
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.model.name, setup.configuration.model.name)
        XCTAssertEqual(prepared.first?.languages, setup.configuration.languages)
        await owner.finish()
    }

    func testPreparationAndRealtimeSetupOverlapAutoLearnWithoutDroppingPreviousEdits() async throws {
        let autoLearnGate = PreparationGate()
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        let session = PreparationSession()
        let modelEntered = expectation(description: "model starts before Auto Learn completes")
        let sessionEntered = expectation(description: "realtime starts before Auto Learn completes")
        var retired = false
        var setupReturned = false
        owner.start(
            resolveConfiguration: { self.makeConfiguration(realtime: true) },
            retireAutoLearn: { await autoLearnGate.wait(); retired = true },
            prepareModel: { _ in modelEntered.fulfill() },
            prepareSession: { configuration in
                _ = try await session.prepare(configuration: configuration)
                sessionEntered.fulfill()
                return session
            }
        )
        let setupTask = Task { let setup = try await owner.setup(); setupReturned = true; return setup }
        await fulfillment(of: [modelEntered, sessionEntered], timeout: 3)
        XCTAssertFalse(retired)
        XCTAssertFalse(setupReturned)

        autoLearnGate.open()
        let setup = try await setupTask.value

        XCTAssertTrue(retired)
        XCTAssertTrue(setup?.session === session)
        XCTAssertEqual(session.configurations.first?.isRealtimeEnabled, true)
        await owner.finish()
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testCancellationBeforeModeCompletionRejectsLateConfiguration() async throws {
        let modeGate = PreparationGate()
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var resolved = false
        var prepared = false
        owner.ownModeResolution(Task { await modeGate.wait() })
        owner.start(
            resolveConfiguration: { resolved = true; return self.makeConfiguration() },
            retireAutoLearn: {}, prepareModel: { _ in prepared = true }, prepareSession: { _ in nil }
        )
        await modeGate.waitUntilEntered()

        owner.cancel()
        modeGate.open()
        await owner.finish()

        XCTAssertFalse(resolved)
        XCTAssertFalse(prepared)
        XCTAssertTrue(owner.isCancelled)
        let canceledSetup = try await owner.setup()
        XCTAssertNil(canceledSetup)
    }

    func testFinishWaitsForUncooperativePreparationBeforeRestartCleanup() async throws {
        let modelGate = PreparationGate()
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var mutationFinished = false
        var finished = false
        owner.start(
            resolveConfiguration: { self.makeConfiguration() }, retireAutoLearn: {},
            prepareModel: { _ in await modelGate.wait(); mutationFinished = true }, prepareSession: { _ in nil }
        )
        await modelGate.waitUntilEntered()
        owner.cancel()
        let finishing = Task { await owner.finish(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished)
        XCTAssertFalse(mutationFinished)

        modelGate.open()
        await finishing.value
        let next = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        next.start(
            resolveConfiguration: { self.makeConfiguration(modelName: "ggml-medium") }, retireAutoLearn: {},
            prepareModel: { _ in XCTAssertTrue(mutationFinished) }, prepareSession: { _ in nil }
        )
        let setup = try await next.setup()
        await next.waitUntilPrepared()

        XCTAssertTrue(finished)
        XCTAssertEqual(setup?.configuration.model.name, "ggml-medium")
        XCTAssertNotEqual(next.recordingID, owner.recordingID)
        XCTAssertFalse(next.isCancelled)
        XCTAssertEqual(owner.timing.snapshot.first(where: { $0.phase == .preparationFinished })?.outcome, .canceled)
        await next.finish()
    }

    func testCanceledRealtimePreparationCannotPublishSessionToRestart() async throws {
        let sessionGate = PreparationGate()
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        let session = PreparationSession()
        owner.start(
            resolveConfiguration: { self.makeConfiguration(realtime: true) }, retireAutoLearn: {},
            prepareModel: { _ in }, prepareSession: { _ in await sessionGate.wait(); return session }
        )
        await sessionGate.waitUntilEntered()
        owner.cancel()
        sessionGate.open()
        await owner.finish()

        do {
            _ = try await owner.setup()
            XCTFail("Canceled preparation must not publish a session")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(session.cancelCount, 1)
    }

    func testRepeatedPreparationRunsOnceAndFailedWarmupLeavesTranscriptionSetupUsable() async throws {
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var calls = 0
        let prepare: @MainActor (TranscriptionRuntimeConfiguration) async throws -> Void = { _ in
            calls += 1
            throw CocoaError(.fileReadNoSuchFile)
        }
        for _ in 0..<3 {
            owner.start(
                resolveConfiguration: { self.makeConfiguration() }, retireAutoLearn: {},
                prepareModel: prepare, prepareSession: { _ in nil }
            )
        }

        let setup = try await owner.setup()
        await owner.waitUntilPrepared()

        XCTAssertEqual(calls, 1)
        XCTAssertNotNil(setup)
        XCTAssertEqual(owner.timing.snapshot.first(where: { $0.phase == .preparationFinished })?.outcome, .failed)
        await owner.finish()
    }

    func testTimingBoundsDuplicatesRejectsForeignAudioTimestampAndSeparatesPosting() {
        let trace = RecordingTimingTrace(originNanoseconds: 100)
        trace.mark(.firstAudio, at: 99)
        trace.mark(.firstAudio, at: 120)
        trace.mark(.firstAudio, at: 150)
        trace.mark(.pasteCommandPosted, at: 200)
        for phase in RecordingTimingTrace.Phase.allCases {
            trace.mark(phase, at: 300)
            trace.mark(phase, outcome: .failed, at: 400)
        }

        XCTAssertEqual(trace.snapshot.count, RecordingTimingTrace.Phase.allCases.count)
        XCTAssertEqual(trace.snapshot.first(where: { $0.phase == .firstAudio })?.elapsedNanoseconds, 20)
        XCTAssertEqual(trace.snapshot.first(where: { $0.phase == .pasteCommandPosted })?.elapsedNanoseconds, 100)
        XCTAssertFalse(RecordingTimingTrace.Phase.allCases.map(\.rawValue).contains("inserted"))
    }

    func testFinishAwaitsRealStreamingStartupAndAsyncDisconnectBeforeRestart() async throws {
        let connectGate = PreparationGate()
        let disconnectGate = PreparationGate()
        let provider = HeldPreparationProvider(connectGate: connectGate, disconnectGate: disconnectGate)
        let fallback = PreparationFallback()
        let session = try makeStreamingSession(provider: provider, fallback: fallback)
        let owner = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        var finished = false
        owner.start(
            resolveConfiguration: { self.makeConfiguration(realtime: true) }, retireAutoLearn: {},
            prepareModel: { _ in },
            prepareSession: { configuration in
                _ = try await session.prepare(configuration: configuration)
                return session
            }
        )
        _ = try await owner.setup()
        await connectGate.waitUntilEntered()

        owner.cancel()
        let finishing = Task { await owner.finish(); finished = true }
        await disconnectGate.waitUntilEntered()
        XCTAssertFalse(finished)
        disconnectGate.open()
        XCTAssertFalse(provider.connectionFinished)
        connectGate.open()
        await finishing.value

        XCTAssertTrue(finished)
        XCTAssertTrue(provider.connectionFinished)
        XCTAssertEqual(provider.activeDisconnects, 0)
        XCTAssertGreaterThan(provider.disconnectCount, 0)
        XCTAssertTrue(fallback.requests.isEmpty)
        do {
            _ = try await session.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"))
            XCTFail("Canceled streaming must not enter batch fallback")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testShortStopAwaitsStreamingConnectionAndDrainsFinalBufferedAudio() async throws {
        let connectGate = PreparationGate()
        let provider = HeldPreparationProvider(connectGate: connectGate)
        let fallback = PreparationFallback()
        let session = try makeStreamingSession(provider: provider, fallback: fallback)
        let callback = try await session.prepare(configuration: makeConfiguration(realtime: true))
        callback?(Data([1, 2]))
        await connectGate.waitUntilEntered()
        var stopped = false

        let stopping = Task {
            let text = try await session.transcribe(audioURL: URL(fileURLWithPath: "/unused.wav"))
            stopped = true
            return text
        }
        await Task.yield()
        XCTAssertFalse(stopped)
        callback?(Data([3, 4]))
        connectGate.open()
        let text = try await stopping.value

        XCTAssertEqual(text, "Streamed fixture")
        XCTAssertEqual(provider.chunks, [Data([1, 2]), Data([3, 4])])
        XCTAssertTrue(fallback.requests.isEmpty)
        session.cancel()
        await session.finishPreparation()
    }

    func testShortStopBatchFallbackRetainsResolvedModelAndLanguageSnapshot() async throws {
        let connectGate = PreparationGate()
        let provider = HeldPreparationProvider(connectGate: connectGate, stopDisposition: .useBatchFallback)
        let fallback = PreparationFallback()
        let session = try makeStreamingSession(provider: provider, fallback: fallback)
        let configuration = makeConfiguration(languages: ["es", "en"], modelName: "ggml-medium", realtime: true)
        _ = try await session.prepare(configuration: configuration)
        await connectGate.waitUntilEntered()
        let url = URL(fileURLWithPath: "/closed-recording.wav")

        let stopping = Task { try await session.transcribe(audioURL: url) }
        connectGate.open()
        let text = try await stopping.value

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(fallback.requests.count, 1)
        XCTAssertEqual(fallback.requests.first?.url, url)
        XCTAssertEqual(fallback.requests.first?.modelName, configuration.model.name)
        XCTAssertEqual(fallback.requests.first?.languages, ["es", "en"])
        session.cancel()
        await session.finishPreparation()
    }

    private func makeStreamingSession(
        provider: HeldPreparationProvider, fallback: PreparationFallback
    ) throws -> StreamingTranscriptionSession {
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let service = StreamingTranscriptionService(
            modelContext: ModelContext(container), providerFactory: { _ in provider }
        )
        return StreamingTranscriptionSession(streamingService: service, fallbackService: fallback)
    }

    private func makeConfiguration(
        languages: [String] = ["en"], modelName: String = "ggml-small", realtime: Bool = false
    ) -> TranscriptionRuntimeConfiguration {
        TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Preparation fixture", isAIEnhancementEnabled: false),
            model: ImportedWhisperModel(fileBaseName: modelName), languages: languages, isRealtimeEnabled: realtime
        )
    }
}

@MainActor
private final class PreparationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var entered = false

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func open() {
        isOpen = true
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class HeldPreparationProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private struct State {
        var connectionFinished = false
        var disconnectCount = 0
        var activeDisconnects = 0
        var chunks: [Data] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let connectGate: PreparationGate
    private let disconnectGate: PreparationGate?
    let stopDisposition: StreamingStopDisposition
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent> = AsyncStream { $0.finish() }
    let finalizationEvents: AsyncStream<String>?
    private let finalization: AsyncStream<String>.Continuation

    init(
        connectGate: PreparationGate, disconnectGate: PreparationGate? = nil,
        stopDisposition: StreamingStopDisposition = .finalizeStreaming
    ) {
        self.connectGate = connectGate
        self.disconnectGate = disconnectGate
        self.stopDisposition = stopDisposition
        let stream = AsyncStream.makeStream(of: String.self)
        finalizationEvents = stream.stream
        finalization = stream.continuation
    }

    var connectionFinished: Bool { state.withLock { $0.connectionFinished } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }
    var activeDisconnects: Int { state.withLock { $0.activeDisconnects } }
    var chunks: [Data] { state.withLock { $0.chunks } }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        await connectGate.wait()
        state.withLock { $0.connectionFinished = true }
    }
    func sendAudioChunk(_ data: Data) async throws { state.withLock { $0.chunks.append(data) } }
    func commit() async throws {
        finalization.yield("Streamed fixture")
        finalization.finish()
    }
    func disconnect() async {
        state.withLock { $0.disconnectCount += 1; $0.activeDisconnects += 1 }
        await disconnectGate?.wait()
        state.withLock { $0.activeDisconnects -= 1 }
        finalization.finish()
    }
}

@MainActor
private final class PreparationFallback: TranscriptionService {
    struct Request {
        let url: URL
        let modelName: String
        let languages: [String]
    }
    var requests: [Request] = []
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        requests.append(Request(url: audioURL, modelName: model.name, languages: context.languages))
        return "Batch fixture"
    }
}

@MainActor
private final class PreparationSession: TranscriptionSession {
    var configurations: [TranscriptionRuntimeConfiguration] = []
    var cancelCount = 0

    func prepare(configuration: TranscriptionRuntimeConfiguration) async throws -> ((Data) -> Void)? {
        configurations.append(configuration)
        return { _ in }
    }
    func transcribe(audioURL: URL) async throws -> String { "Fixture transcription" }
    func cancel() { cancelCount += 1 }
}
