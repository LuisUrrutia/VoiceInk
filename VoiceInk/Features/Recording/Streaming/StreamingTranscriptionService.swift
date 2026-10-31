import Foundation
import os

/// Sendable source that bridges audio chunks from any thread into an AsyncStream.
private final class AudioChunkSource: @unchecked Sendable {
    let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingOldest(2_048)
        )
        self.stream = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    func send(_ data: Data) -> Bool {
        switch continuation.yield(data) {
        case .enqueued(_):
            return true
        case .dropped(_), .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func finish() {
        continuation.finish()
    }
}

private final class StreamingMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedChunks = 0
    private var receivedBytes = 0
    private var sentChunks = 0
    private var sentBytes = 0
    private var droppedChunks = 0
    private var droppedBytes = 0

    func reset() {
        lock.lock()
        receivedChunks = 0
        receivedBytes = 0
        sentChunks = 0
        sentBytes = 0
        droppedChunks = 0
        droppedBytes = 0
        lock.unlock()
    }

    func recordReceived(_ byteCount: Int) {
        lock.lock()
        receivedChunks += 1
        receivedBytes += byteCount
        lock.unlock()
    }

    func recordSent(_ byteCount: Int) {
        lock.lock()
        sentChunks += 1
        sentBytes += byteCount
        lock.unlock()
    }

    func recordDropped(_ byteCount: Int) {
        lock.lock()
        droppedChunks += 1
        droppedBytes += byteCount
        lock.unlock()
    }

    func snapshot() -> (
        receivedChunks: Int,
        receivedBytes: Int,
        sentChunks: Int,
        sentBytes: Int,
        droppedChunks: Int,
        droppedBytes: Int
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (receivedChunks, receivedBytes, sentChunks, sentBytes, droppedChunks, droppedBytes)
    }
}

/// Lifecycle states for a streaming transcription session.
enum StreamingState {
    case idle
    case connecting
    case streaming
    case committing
    case done
    case failed
    case cancelled
}

enum StreamingStopResult {
    case finalized(text: String)
    case requiresBatchFallback
}

/// Durations of the stop phases of the most recent finish, for logs and measurement.
struct StreamingFinishPhases: Equatable {
    var drain: Duration?
    var commit: Duration?
    var wait: Duration?
}

private enum StreamingFinishOutcome {
    case finalized(String)
    /// The provider's terminal acknowledgement ended without a transcript.
    case unconfirmed
    case failed(Error)
    case deadlineExceeded(Task<Void, Never>)
    case cancelled(Task<Void, Never>)

    var label: String {
        switch self {
        case .finalized: "finalized"
        case .unconfirmed: "unconfirmed"
        case .failed: "failed"
        case .deadlineExceeded: "deadline"
        case .cancelled: "cancelled"
        }
    }
}

private enum StreamingFinalizationWait {
    case provider(AsyncStream<String>)
    case committedEvent(AsyncStream<Void>)
}

/// Manages a streaming transcription lifecycle: buffers audio chunks, sends them to the provider, and collects the final text.
@MainActor
class StreamingTranscriptionService {

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "StreamingTranscriptionService")
    private var provider: StreamingTranscriptionProvider?
    private var sendTask: Task<Void, Never>?
    private var eventConsumerTask: Task<Void, Never>?
    private var cancellationTask: Task<Void, Never>?
    private let chunkSource = AudioChunkSource()
    private var state: StreamingState = .idle
    private var committedSegments: [String] = []
    private let fluidAudioService: FluidAudioTranscriptionService?
    private let providerFactory: ((any TranscriptionModel) -> StreamingTranscriptionProvider)?
    private let finishDeadlineSleep: @Sendable (Duration) async throws -> Void
    private var activeFinish: (outcomes: AsyncStream<StreamingFinishOutcome>.Continuation, task: Task<Void, Never>)?
    private var onPartialTranscript: ((String) -> Void)?
    private let metrics = StreamingMetrics()
    private var stopStartedAt: Date?
    private var firstPartialLogged = false
    private var firstCommitLogged = false
    private(set) var lastFinishPhases = StreamingFinishPhases()

    init(
        fluidAudioService: FluidAudioTranscriptionService? = nil,
        onPartialTranscript: ((String) -> Void)? = nil,
        providerFactory: ((any TranscriptionModel) -> StreamingTranscriptionProvider)? = nil,
        finishDeadlineSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.fluidAudioService = fluidAudioService
        self.onPartialTranscript = onPartialTranscript
        self.providerFactory = providerFactory
        self.finishDeadlineSleep = finishDeadlineSleep
    }

    deinit {
        onPartialTranscript = nil
        sendTask?.cancel()
        eventConsumerTask?.cancel()
        chunkSource.finish()
        commitSignal?.finish()
    }

    /// Signal used to notify `finishStream` when a new committed segment arrives.
    private var commitSignal: AsyncStream<Void>.Continuation?

    /// Whether the streaming connection is fully established and actively sending.
    var isActive: Bool { state == .streaming || state == .committing }

    /// Start a streaming transcription session for the given model.
    func startStreaming(model: any TranscriptionModel, context: TranscriptionRequestContext) async throws {
        try Task.checkCancellation()
        let start = Date()
        state = .connecting
        committedSegments = []
        metrics.reset()
        firstPartialLogged = false
        firstCommitLogged = false

        let provider = createProvider(for: model, vocabulary: context.vocabulary ?? RecordingVocabulary())
        self.provider = provider

        let selectedLanguage = context.language ?? "auto"
        logger.notice(
            "Streaming start requested model=\(model.displayName, privacy: .public) language=\(selectedLanguage, privacy: .public)"
        )

        try await provider.connect(model: model, language: selectedLanguage)

        // If cancel() was called while we were awaiting the connection, tear down immediately.
        if state == .cancelled {
            await provider.disconnect()
            self.provider = nil
            return
        }

        state = .streaming
        startSendLoop()
        startEventConsumer()

        logger.notice(
            "Streaming connected model=\(model.displayName, privacy: .public) elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s"
        )
    }

    /// Buffers an audio chunk for sending. Safe to call from the recorder processing queue.
    nonisolated func sendAudioChunk(_ data: Data) {
        metrics.recordReceived(data.count)
        if !chunkSource.send(data) {
            metrics.recordDropped(data.count)
        }
    }

    /// Stops streaming and follows the provider's requested finalization path. Draining, committing and the
    /// final transcript share the provider's `finishDeadline`, measured from this call; past it, the recording
    /// uses batch transcription when `batchFallbackAvailable`, and never the partial committed text.
    func stopAndFinalize(batchFallbackAvailable: Bool = true) async throws -> StreamingStopResult {
        guard let provider = provider, state == .streaming else {
            throw StreamingTranscriptionError.notConnected
        }

        if provider is FluidAudioUnifiedStreamingProvider, metrics.snapshot().droppedChunks > 0 {
            logger.warning("Unified streaming dropped audio; using the full recording for batch transcription")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        if provider.stopDisposition == .useBatchFallback {
            logger.notice("Streaming provider requested full batch fallback")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        }

        state = .committing
        stopStartedAt = Date()
        let beforeDrain = metrics.snapshot()
        logger.notice(
            "Streaming stop requested receivedChunks=\(beforeDrain.receivedChunks, privacy: .public) sentChunks=\(beforeDrain.sentChunks, privacy: .public) droppedChunks=\(beforeDrain.droppedChunks, privacy: .public) receivedBytes=\(beforeDrain.receivedBytes, privacy: .public) sentBytes=\(beforeDrain.sentBytes, privacy: .public) droppedBytes=\(beforeDrain.droppedBytes, privacy: .public)"
        )

        let deadline = provider.finishDeadline
        let outcome = await finishWithinDeadline(provider, deadline: deadline)
        if let stopStartedAt {
            logger.notice(
                "Streaming stop finished outcome=\(outcome.label, privacy: .public) elapsed=\(Date().timeIntervalSince(stopStartedAt), format: .fixed(precision: 3), privacy: .public)s deadline=\(deadline, privacy: .public)"
            )
        }
        if state == .cancelled {
            if case .deadlineExceeded(let finishing) = outcome { cancelTeardownIfNeeded(finishing) }
            throw CancellationError()
        }

        switch outcome {
        case .finalized(let text):
            state = .done
            await cleanupStreaming()
            return .finalized(text: text)
        case .unconfirmed:
            logger.warning("Provider did not confirm full stream finalization; using batch fallback")
            state = .done
            await cleanupStreaming()
            return .requiresBatchFallback
        case .failed(let error):
            logger.error("Streaming finish failed: \(error, privacy: .public)")
            state = .failed
            await cleanupStreaming()
            throw error
        case .deadlineExceeded(let finishing):
            // The stalled finish keeps running in the background; finishCancellation awaits it.
            let partial = committedSegments.joined(separator: " ")
            logger.warning(
                "Streaming finish exceeded its deadline; batchFallback=\(batchFallbackAvailable, privacy: .public) partialChars=\(partial.count, privacy: .public)"
            )
            state = .done
            tearDownInBackground(awaiting: finishing)
            // Partial committed text would paste a truncated transcript; only streaming-only providers keep it.
            return batchFallbackAvailable ? .requiresBatchFallback : .finalized(text: partial)
        case .cancelled(let finishing):
            cancelTeardownIfNeeded(finishing)
            throw CancellationError()
        }
    }

    /// Cancels the streaming session without waiting for results.
    func cancel() {
        state = .cancelled
        let finish = activeFinish
        activeFinish = nil
        if let finish { finish.outcomes.yield(.cancelled(finish.task)) }
        tearDownInBackground(awaiting: finish?.task)
        logger.notice("Streaming cancelled")
    }

    private func cancelTeardownIfNeeded(_ finishing: Task<Void, Never>) {
        guard !finishing.isCancelled else { return }
        state = .cancelled
        tearDownInBackground(awaiting: finishing)
    }

    /// Stops all streaming work without awaiting it; `finishCancellation` awaits the teardown.
    private func tearDownInBackground(awaiting finishing: Task<Void, Never>?) {
        onPartialTranscript = nil
        let eventConsumer = eventConsumerTask
        let sender = sendTask
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        finishing?.cancel()
        chunkSource.finish()

        // Clean up commit signal if waiting
        commitSignal?.finish()
        commitSignal = nil

        let providerToDisconnect = provider
        provider = nil

        if providerToDisconnect != nil || eventConsumer != nil || sender != nil || finishing != nil {
            let previousCancellation = cancellationTask
            cancellationTask = Task {
                await previousCancellation?.value
                await providerToDisconnect?.disconnect()
                await sender?.value
                await eventConsumer?.value
                await finishing?.value
            }
        }

        committedSegments = []
    }

    func finishCancellation() async {
        await cancellationTask?.value
    }

    // MARK: - Private

    private func createProvider(
        for model: any TranscriptionModel, vocabulary: RecordingVocabulary
    ) -> StreamingTranscriptionProvider {
        if let providerFactory { return providerFactory(model) }
        if model.provider == .fluidAudio {
            if FluidAudioModelManager.isNemotronModel(named: model.name) {
                return FluidAudioNemotronStreamingProvider()
            }

            if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
                guard let fluidAudioService else {
                    fatalError("FluidAudioTranscriptionService required for Unified streaming")
                }
                return FluidAudioUnifiedStreamingProvider(fluidAudioService: fluidAudioService)
            }

            guard let fluidAudioService else {
                fatalError(
                    "FluidAudioTranscriptionService required for FluidAudio streaming. Ensure it is passed to StreamingTranscriptionService."
                )
            }
            return FluidAudioStreamingProvider(fluidAudioService: fluidAudioService)
        }
        guard let cloudProvider = CloudProviderRegistry.provider(for: model.provider),
            let streamingProvider = cloudProvider.makeStreamingProvider(vocabulary: vocabulary)
        else {
            fatalError(
                "Unsupported streaming provider: \(model.provider). Check shouldUseRealtimeTranscription() before calling startStreaming()."
            )
        }
        return streamingProvider
    }

    /// Consumes audio chunks from the AsyncStream and sends them to the provider.
    private func startSendLoop() {
        let source = chunkSource
        let provider = provider
        let metrics = metrics
        let logger = logger

        sendTask = Task.detached {
            for await chunk in source.stream {
                do {
                    try await provider?.sendAudioChunk(chunk)
                    metrics.recordSent(chunk.count)
                } catch {
                    let desc = error.localizedDescription
                    logger.error("Failed to send audio chunk: \(desc, privacy: .public)")
                }
            }
        }
    }

    /// Finishes the chunk source and waits for the send loop to process all remaining buffered chunks.
    private func drainRemainingChunks() async {
        let start = Date()
        chunkSource.finish()
        await sendTask?.value
        sendTask = nil
        let snapshot = metrics.snapshot()
        logger.notice(
            "Streaming drain finished elapsed=\(Date().timeIntervalSince(start), format: .fixed(precision: 3), privacy: .public)s receivedChunks=\(snapshot.receivedChunks, privacy: .public) sentChunks=\(snapshot.sentChunks, privacy: .public) droppedChunks=\(snapshot.droppedChunks, privacy: .public) receivedBytes=\(snapshot.receivedBytes, privacy: .public) sentBytes=\(snapshot.sentBytes, privacy: .public) droppedBytes=\(snapshot.droppedBytes, privacy: .public)"
        )
    }

    /// Consumes transcription events throughout the session, accumulating committed segments.
    private func startEventConsumer() {
        guard let provider = provider else { return }
        let events = provider.transcriptionEvents

        eventConsumerTask = Task.detached { [weak self] in
            for await event in events {
                guard let self = self else { break }
                switch event {
                case .committed(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run {
                        if !self.firstCommitLogged {
                            self.firstCommitLogged = true
                            let elapsed = self.stopStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                            self.logger.notice(
                                "Streaming first committed event chars=\(trimmed.count, privacy: .public) stopElapsed=\(elapsed, format: .fixed(precision: 3), privacy: .public)s"
                            )
                        }
                        if !trimmed.isEmpty {
                            self.committedSegments.append(trimmed)
                        }
                        // Refresh the live preview so it keeps showing the full running transcript
                        // after a commit (instead of resetting to empty until the next partial).
                        if self.state == .streaming {
                            self.onPartialTranscript?(self.committedSegments.joined(separator: " "))
                        }
                        if self.state == .committing {
                            self.commitSignal?.yield()
                        }
                    }
                case .partial(let text):
                    await MainActor.run {
                        if !self.firstPartialLogged {
                            self.firstPartialLogged = true
                            self.logger.notice("Streaming first partial event chars=\(text.count, privacy: .public)")
                        }
                        if self.state == .streaming {
                            let prefix = self.committedSegments.joined(separator: " ")
                            let display: String
                            if prefix.isEmpty {
                                display = text
                            } else if text.hasPrefix(prefix) || text.hasPrefix(prefix + " ") {
                                // Provider already sends cumulative partials (e.g. FluidAudio fullText).
                                display = text
                            } else {
                                display = prefix + " " + text
                            }
                            self.onPartialTranscript?(display)
                        }
                    }
                case .sessionStarted:
                    break
                case .error(let error):
                    await MainActor.run {
                        self.logger.error("Streaming event error: \(error, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Runs drain, commit and the final wait, and returns the first of their outcome, the deadline or cancellation.
    private func finishWithinDeadline(
        _ provider: StreamingTranscriptionProvider, deadline: Duration
    ) async -> StreamingFinishOutcome {
        let (outcomes, continuation) = AsyncStream.makeStream(of: StreamingFinishOutcome.self)
        // Unstructured, so a finish that ignores cancellation (a CoreML pass) cannot hold the deadline open.
        let finishing = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                continuation.yield(try await self.finishStream(provider))
            } catch {
                continuation.yield(.failed(error))
            }
        }
        activeFinish = (continuation, finishing)
        let sleep = finishDeadlineSleep
        let timer = Task {
            guard (try? await sleep(deadline)) != nil else { return }
            continuation.yield(.deadlineExceeded(finishing))
        }
        let outcome = await withTaskCancellationHandler {
            var iterator = outcomes.makeAsyncIterator()
            return await iterator.next() ?? .cancelled(finishing)
        } onCancel: {
            continuation.yield(.cancelled(finishing))
        }
        continuation.finish()
        timer.cancel()
        activeFinish = nil
        return outcome
    }

    private func finishStream(_ provider: StreamingTranscriptionProvider) async throws -> StreamingFinishOutcome {
        lastFinishPhases = StreamingFinishPhases()
        let clock = ContinuousClock()
        var phaseStart = clock.now
        // Finish the chunk source so the send loop drains remaining chunks and exits naturally.
        await drainRemainingChunks()
        try Task.checkCancellation()
        lastFinishPhases.drain = clock.now - phaseStart
        phaseStart = clock.now

        // Providers with a documented terminal acknowledgement expose an authoritative
        // full-transcript stream. All other providers retain the existing committed-event behavior.
        let finalizationWait: StreamingFinalizationWait
        if let finalizationEvents = provider.finalizationEvents {
            finalizationWait = .provider(finalizationEvents)
        } else {
            // Set up the commit signal BEFORE sending commit to avoid a race with the response.
            let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
            self.commitSignal = signalContinuation
            finalizationWait = .committedEvent(signalStream)
        }

        // Send commit to finalize any remaining audio
        do {
            try await provider.commit()
        } catch {
            commitSignal?.finish()
            commitSignal = nil
            throw error
        }
        try Task.checkCancellation()
        lastFinishPhases.commit = clock.now - phaseStart
        phaseStart = clock.now

        switch finalizationWait {
        case .provider(let events):
            var iterator = events.makeAsyncIterator()
            let text = await iterator.next()
            lastFinishPhases.wait = clock.now - phaseStart
            return text.map { .finalized($0) } ?? .unconfirmed
        case .committedEvent(let signalStream):
            for await _ in signalStream { break }
            commitSignal?.finish()
            commitSignal = nil
            lastFinishPhases.wait = clock.now - phaseStart
            return .finalized(committedSegments.joined(separator: " "))
        }
    }

    private func cleanupStreaming() async {
        onPartialTranscript = nil
        let eventConsumer = eventConsumerTask
        let sender = sendTask
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        sendTask?.cancel()
        sendTask = nil
        chunkSource.finish()
        commitSignal?.finish()
        commitSignal = nil
        await provider?.disconnect()
        await sender?.value
        await eventConsumer?.value
        provider = nil
        state = .idle
        committedSegments = []
    }
}
