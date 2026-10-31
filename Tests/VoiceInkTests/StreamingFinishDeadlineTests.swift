import Foundation
import os
import XCTest
@testable import VoiceInk

@MainActor
final class StreamingFinishDeadlineTests: XCTestCase {
    private let clipURL = URL(fileURLWithPath: "/closed-recording.wav")

    func testOnTimeFinalTextIsDeliveredWithoutFallback() async throws {
        let provider = FinishFakeProvider(finalText: "Streamed text")
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let text = try await session.transcribe(audioURL: clipURL, vocabulary: RecordingVocabulary())

        XCTAssertEqual(text, "Streamed text")
        XCTAssertTrue(fallback.requests.isEmpty)
        XCTAssertEqual(provider.commitCount, 1)
        await finish(session)
    }

    func testStalledDrainFallsBackToTheWholeClip() async throws {
        let drain = Latch()
        let provider = FinishFakeProvider(finalText: "Streamed text", sendGate: drain)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline, chunks: [Data([1, 2])])
        await drain.waitUntilEntered()

        let text = try await stopAtDeadline(session, deadline: deadline)

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(fallback.requests.map(\.url), [clipURL])
        XCTAssertEqual(provider.commitCount, 0)
        drain.open()
        await finish(session)
    }

    func testStalledCommitFallsBackWithoutAwaitingTheStalledFinish() async throws {
        let commit = Latch()
        let provider = FinishFakeProvider(finalText: "Streamed text", commitGate: commit)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let stopping = Task { try await session.transcribe(audioURL: self.clipURL, vocabulary: RecordingVocabulary()) }
        await commit.waitUntilEntered()
        await deadline.waitUntilRequested()
        deadline.fire()
        let text = try await stopping.value

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(fallback.requests.count, 1)
        var finished = false
        let finishing = Task { await session.finishPreparation(); finished = true }
        await Task.yield()
        XCTAssertFalse(finished, "The owner awaits the abandoned finish before releasing resources")
        commit.open()
        await finishing.value
        XCTAssertTrue(finished)
        XCTAssertGreaterThan(provider.disconnectCount, 0)
    }

    func testMissingFinalEventFallsBack() async throws {
        let provider = FinishFakeProvider(finalText: nil)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let text = try await stopAtDeadline(session, deadline: deadline)

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(provider.commitCount, 1)
        XCTAssertEqual(fallback.requests.count, 1)
        await finish(session)
    }

    func testPartialCommittedTextIsNeverReturnedAfterTheDeadline() async throws {
        let provider = FinishFakeProvider(finalText: nil)
        let deadline = ManualDeadline()
        let partials = PartialTranscripts()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline, partials: partials)
        provider.emitCommitted("First half of the")
        try await waitUntil { partials.latest == "First half of the" }

        let text = try await stopAtDeadline(session, deadline: deadline)

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(fallback.requests.map(\.url), [clipURL])
        await finish(session)
    }

    func testOnTimeEmptyTextIsDeliveredWithoutFallback() async throws {
        // A finished Unified stream returned empty text only for silence, where batch is empty too.
        let provider = FinishFakeProvider(finalText: "")
        let (session, fallback) = try await makeSession(provider: provider, deadline: ManualDeadline())

        let text = try await session.transcribe(audioURL: clipURL, vocabulary: RecordingVocabulary())

        XCTAssertEqual(text, "")
        XCTAssertTrue(fallback.requests.isEmpty)
        await finish(session)
    }

    func testCancelDuringTheFinalWaitThrowsWithoutFallback() async throws {
        let commit = Latch()
        let provider = FinishFakeProvider(finalText: "Streamed text", commitGate: commit)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let stopping = Task { try await session.transcribe(audioURL: self.clipURL, vocabulary: RecordingVocabulary()) }
        await commit.waitUntilEntered()
        session.cancel()

        await XCTAssertThrowsCancellation { try await stopping.value }
        XCTAssertTrue(fallback.requests.isEmpty)
        commit.open()
        await session.finishPreparation()
    }

    func testTaskCancellationDuringTheFinalWaitThrowsWithoutFallback() async throws {
        let provider = FinishFakeProvider(finalText: nil)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let stopping = Task { try await session.transcribe(audioURL: self.clipURL, vocabulary: RecordingVocabulary()) }
        await deadline.waitUntilRequested()
        stopping.cancel()

        await XCTAssertThrowsCancellation { try await stopping.value }
        XCTAssertTrue(fallback.requests.isEmpty)
        await finish(session)
    }

    func testExplicitFinalizationArrivesOnTime() async throws {
        let provider = FinishFakeProvider(finalText: "Authoritative text", explicitFinalization: true)
        let (session, fallback) = try await makeSession(provider: provider, deadline: ManualDeadline())

        let text = try await session.transcribe(audioURL: clipURL, vocabulary: RecordingVocabulary())

        XCTAssertEqual(text, "Authoritative text")
        XCTAssertTrue(fallback.requests.isEmpty)
        await finish(session)
    }

    func testExplicitFinalizationPastTheDeadlineFallsBack() async throws {
        let provider = FinishFakeProvider(finalText: nil, explicitFinalization: true)
        let deadline = ManualDeadline()
        let (session, fallback) = try await makeSession(provider: provider, deadline: deadline)

        let text = try await stopAtDeadline(session, deadline: deadline)

        XCTAssertEqual(text, "Batch fixture")
        XCTAssertEqual(fallback.requests.count, 1)
        await finish(session)
    }

    func testDeadlineIsTheProvidersAndCoversDrainCommitAndWait() async throws {
        let provider = FinishFakeProvider(finalText: "Streamed text", deadline: .milliseconds(1_234))
        let deadline = ManualDeadline()
        let (session, _) = try await makeSession(provider: provider, deadline: deadline)

        _ = try await session.transcribe(audioURL: clipURL, vocabulary: RecordingVocabulary())

        XCTAssertEqual(deadline.requested, [.milliseconds(1_234)])
        XCTAssertTrue(deadline.wasCancelled, "An on-time finish stops the deadline timer")
        await finish(session)
    }

    func testProviderDeadlines() {
        let unified = FluidAudioUnifiedStreamingProvider(fluidAudioService: FluidAudioTranscriptionService())
        XCTAssertEqual(unified.finishDeadline, FluidAudioUnifiedStreamingProvider.finishDeadline)
        XCTAssertLessThan(unified.finishDeadline, .seconds(10))
        XCTAssertEqual(DeepgramStreamingProvider(customVocabulary: []).finishDeadline, .seconds(10))
        XCTAssertEqual(CartesiaStreamingProvider(customVocabulary: []).finishDeadline, .seconds(10))
    }

    func testStreamingOnlyProviderKeepsCommittedTextAtTheDeadline() async throws {
        let provider = FinishFakeProvider(finalText: nil)
        let deadline = ManualDeadline()
        let model = try XCTUnwrap(CartesiaProvider().models.first)
        let partials = PartialTranscripts()
        let (session, fallback) = try await makeSession(
            provider: provider, deadline: deadline, model: model, partials: partials
        )
        provider.emitCommitted("Only streamed words")
        try await waitUntil { partials.latest == "Only streamed words" }

        let text = try await stopAtDeadline(session, deadline: deadline)

        XCTAssertEqual(text, "Only streamed words")
        XCTAssertTrue(fallback.requests.isEmpty)
        await finish(session)
    }

    func testStreamingOnlyProviderReturnsEmptyTextWithoutFallback() async throws {
        let provider = FinishFakeProvider(finalText: "")
        let model = try XCTUnwrap(CartesiaProvider().models.first)
        let (session, fallback) = try await makeSession(provider: provider, deadline: ManualDeadline(), model: model)

        let text = try await session.transcribe(audioURL: clipURL, vocabulary: RecordingVocabulary())

        XCTAssertEqual(text, "")
        XCTAssertTrue(fallback.requests.isEmpty)
        await finish(session)
    }

    // MARK: - Helpers

    private func makeSession(
        provider: FinishFakeProvider, deadline: ManualDeadline, chunks: [Data] = [],
        model: (any TranscriptionModel)? = nil, partials: PartialTranscripts? = nil
    ) async throws -> (StreamingTranscriptionSession, FinishFallback) {
        // The detached event consumer appends a committed segment after the provider yields it.
        let service = StreamingTranscriptionService(
            onPartialTranscript: { partials?.latest = $0 },
            providerFactory: { _ in provider }, finishDeadlineSleep: { try await deadline.sleep($0) }
        )
        let fallback = FinishFallback()
        let session = StreamingTranscriptionSession(streamingService: service, fallbackService: fallback)
        let configuration = TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Finish fixture", isAIEnhancementEnabled: false),
            model: model ?? ImportedWhisperModel(fileBaseName: "ggml-small"), languages: ["en"], isRealtimeEnabled: true
        )
        let callback = try await session.prepare(configuration: configuration, vocabulary: RecordingVocabulary())
        try await waitUntil { service.isActive }
        chunks.forEach { callback?($0) }
        return (session, fallback)
    }

    private func stopAtDeadline(_ session: StreamingTranscriptionSession, deadline: ManualDeadline) async throws -> String {
        let stopping = Task { try await session.transcribe(audioURL: self.clipURL, vocabulary: RecordingVocabulary()) }
        await deadline.waitUntilRequested()
        deadline.fire()
        return try await stopping.value
    }

    private func finish(_ session: StreamingTranscriptionSession) async {
        session.cancel()
        await session.finishPreparation()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 where !condition() {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition())
    }

    private func XCTAssertThrowsCancellation(
        _ operation: () async throws -> String, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }
}

/// A gate that ignores task cancellation, like a CoreML pass in progress.
private final class Latch: @unchecked Sendable {
    private struct State {
        var isOpen = false
        var entered = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.entered = true
                let entered = state.enteredWaiters
                state.enteredWaiters.removeAll()
                if state.isOpen { return entered + [continuation] }
                state.waiters.append(continuation)
                return entered
            }
            resume.forEach { $0.resume() }
        }
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            let entered = state.withLock { state -> Bool in
                if !state.entered { state.enteredWaiters.append(continuation) }
                return state.entered
            }
            if entered { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}

/// Replaces the wall-clock deadline: it elapses only when the test fires it.
private final class ManualDeadline: @unchecked Sendable {
    private struct State {
        var requested: [Duration] = []
        var fired = false
        var cancelled = false
        var sleeper: CheckedContinuation<Void, Never>?
        var requestWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var requested: [Duration] { state.withLock { $0.requested } }
    var wasCancelled: Bool { state.withLock { $0.cancelled } }

    func sleep(_ duration: Duration) async throws {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let (resumeNow, waiters) = state.withLock { state -> (Bool, [CheckedContinuation<Void, Never>]) in
                    state.requested.append(duration)
                    let waiters = state.requestWaiters
                    state.requestWaiters.removeAll()
                    if state.fired || state.cancelled { return (true, waiters) }
                    state.sleeper = continuation
                    return (false, waiters)
                }
                waiters.forEach { $0.resume() }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> CheckedContinuation<Void, Never>? in
                state.cancelled = true
                defer { state.sleeper = nil }
                return state.sleeper
            }
            sleeper?.resume()
        }
        try Task.checkCancellation()
    }

    func waitUntilRequested() async {
        await withCheckedContinuation { continuation in
            let requested = state.withLock { state -> Bool in
                if state.requested.isEmpty { state.requestWaiters.append(continuation) }
                return !state.requested.isEmpty
            }
            if requested { continuation.resume() }
        }
    }

    func fire() {
        let sleeper = state.withLock { state -> CheckedContinuation<Void, Never>? in
            state.fired = true
            defer { state.sleeper = nil }
            return state.sleeper
        }
        sleeper?.resume()
    }
}

private final class FinishFakeProvider: StreamingTranscriptionProvider, @unchecked Sendable {
    private struct State {
        var commitCount = 0
        var disconnectCount = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let finalText: String?
    private let sendGate: Latch?
    private let commitGate: Latch?
    private let events: AsyncStream<StreamingTranscriptionEvent>.Continuation
    private let finalization: AsyncStream<String>.Continuation?
    let transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>
    let finalizationEvents: AsyncStream<String>?
    let finishDeadline: Duration

    init(
        finalText: String?, explicitFinalization: Bool = false, sendGate: Latch? = nil, commitGate: Latch? = nil,
        deadline: Duration = .seconds(10)
    ) {
        self.finalText = finalText
        self.sendGate = sendGate
        self.commitGate = commitGate
        finishDeadline = deadline
        (transcriptionEvents, events) = AsyncStream.makeStream(of: StreamingTranscriptionEvent.self)
        if explicitFinalization {
            let (stream, continuation) = AsyncStream.makeStream(of: String.self)
            finalizationEvents = stream
            finalization = continuation
        } else {
            finalizationEvents = nil
            finalization = nil
        }
    }

    var commitCount: Int { state.withLock { $0.commitCount } }
    var disconnectCount: Int { state.withLock { $0.disconnectCount } }

    func emitCommitted(_ text: String) {
        events.yield(.committed(text: text))
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {}

    func sendAudioChunk(_ data: Data) async throws {
        await sendGate?.wait()
    }

    func commit() async throws {
        state.withLock { $0.commitCount += 1 }
        await commitGate?.wait()
        guard let finalText else { return }
        if let finalization {
            finalization.yield(finalText)
        } else {
            events.yield(.committed(text: finalText))
        }
    }

    func disconnect() async {
        state.withLock { $0.disconnectCount += 1 }
        events.finish()
        finalization?.finish()
    }
}

@MainActor
private final class PartialTranscripts {
    var latest = ""
}

@MainActor
private final class FinishFallback: TranscriptionService {
    struct Request {
        let url: URL
        let modelName: String
    }
    var requests: [Request] = []

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws -> String {
        requests.append(Request(url: audioURL, modelName: model.name))
        return "Batch fixture"
    }
}
