import Foundation
import os

final class RealtimeAudioChunkGate: @unchecked Sendable {
    private struct State {
        var bufferedChunks: [Data] = []
        var callback: ((Data) -> Void)?
        var isActive = false
        var droppedChunks = 0
    }

    private let maxBufferedChunks = 2_048
    private let state = OSAllocatedUnfairLock(initialState: State())

    func receive(_ data: Data) {
        let callback = state.withLock { state -> ((Data) -> Void)? in
            guard state.isActive else {
                if state.bufferedChunks.count < maxBufferedChunks {
                    state.bufferedChunks.append(data)
                } else {
                    state.droppedChunks += 1
                }
                return nil
            }
            return state.callback
        }
        callback?(data)
    }

    func activate(_ callback: @escaping (Data) -> Void) -> Int {
        let initialState = state.withLock { state -> (chunks: [Data], droppedChunks: Int) in
            state.callback = callback
            state.isActive = false
            let chunks = state.bufferedChunks
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.droppedChunks = 0
            return (chunks, droppedChunks)
        }
        var chunksToSend = initialState.chunks
        var droppedChunks = initialState.droppedChunks

        while true {
            for chunk in chunksToSend {
                callback(chunk)
            }

            let nextState = state.withLock { state -> (chunks: [Data], droppedChunks: Int, finished: Bool) in
                let droppedChunks = state.droppedChunks
                state.droppedChunks = 0
                guard !state.bufferedChunks.isEmpty else {
                    state.isActive = true
                    return ([], droppedChunks, true)
                }
                let chunks = state.bufferedChunks
                state.bufferedChunks.removeAll()
                return (chunks, droppedChunks, false)
            }
            droppedChunks += nextState.droppedChunks

            if nextState.finished {
                return droppedChunks
            }
            chunksToSend = nextState.chunks
        }
    }

    func reset() -> Int {
        state.withLock { state -> Int in
            let droppedChunks = state.droppedChunks
            state.bufferedChunks.removeAll()
            state.callback = nil
            state.isActive = false
            state.droppedChunks = 0
            return droppedChunks
        }
    }
}

enum DictationUseCase {
    case newSession
    case assistantFollowUp

    var isAssistantFollowUp: Bool {
        self == .assistantFollowUp
    }
}

/// The live microphone capture. There is at most one, because there is one AUHAL.
/// Its preparation holds its mode snapshot and start-sound playback; Stop transfers it all to a `DictationJob`.
@MainActor
final class DictationCapture {
    /// Owns this dictation's share of the transcription residency, through its job.
    let dictationID: UUID
    /// Nil once the capture has ended, so late start and setup completions no longer own it.
    var startID: UUID?
    var delivery: RecordingDeliverySession?
    var preparation: RecordingTranscriptionPreparation?
    var fileURL: URL?
    let audioGate: RealtimeAudioChunkGate?
    var context: RecordingContextCapture.Session?
    let useCase: DictationUseCase
    var session: TranscriptionSession?
    var sessionConfiguration: TranscriptionRuntimeConfiguration?
    var cancelRequested = false
    var phase: RecordingState = .idle {
        didSet { if oldValue != phase { didChangePhase() } }
    }
    private let didChangePhase: @MainActor () -> Void

    init(
        startID: UUID?, delivery: RecordingDeliverySession?, preparation: RecordingTranscriptionPreparation?,
        audioGate: RealtimeAudioChunkGate?, useCase: DictationUseCase,
        didChangePhase: @escaping @MainActor () -> Void
    ) {
        self.startID = startID
        dictationID = startID ?? UUID()
        self.delivery = delivery
        self.preparation = preparation
        self.audioGate = audioGate
        self.useCase = useCase
        self.didChangePhase = didChangePhase
    }
}

/// A stopped dictation, from its awaited hardware stop through transcription, enhancement and delivery.
@MainActor
final class DictationJob {
    let sequence: UInt64
    let dictationID: UUID
    var audioURL: URL?
    var preparation: RecordingTranscriptionPreparation?
    var delivery: RecordingDeliverySession?
    var context: RecordingContextCapture.Session?
    var session: TranscriptionSession?
    var sessionConfiguration: TranscriptionRuntimeConfiguration?
    let useCase: DictationUseCase
    /// From the Stop request (Finish and Send), not the start.
    let sendAfterPaste: Bool
    /// Set when the pending History row exists; nil once the job no longer owns the engine's resources.
    var transcriptionID: UUID?
    /// Never reset: a canceled job stays canceled after the recorder returns to idle.
    var cancelRequested = false
    var task: Task<Void, Never>?
    var phase: RecordingState = .transcribing {
        didSet { if oldValue != phase { didChangePhase() } }
    }
    private let didChangePhase: @MainActor () -> Void

    /// Takes over everything the stopped capture owned.
    init(
        sequence: UInt64, capture: DictationCapture, sendAfterPaste: Bool,
        didChangePhase: @escaping @MainActor () -> Void
    ) {
        self.sequence = sequence
        dictationID = capture.dictationID
        audioURL = capture.fileURL
        preparation = capture.preparation
        delivery = capture.delivery
        context = capture.context
        session = capture.session
        sessionConfiguration = capture.sessionConfiguration
        useCase = capture.useCase
        self.sendAfterPaste = sendAfterPaste
        cancelRequested = capture.cancelRequested
        self.didChangePhase = didChangePhase
    }

    /// Delivery passed its destination guards, after which output to the destination may begin.
    var outputStarted: Bool {
        delivery?.timing.snapshot.contains { $0.phase == .destinationReady && $0.outcome == .completed } ?? false
    }
}
