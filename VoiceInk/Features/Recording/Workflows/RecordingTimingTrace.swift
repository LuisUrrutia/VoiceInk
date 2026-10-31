import Foundation
import os

final class RecordingTimingTrace: @unchecked Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case shortcutPressed, requestReceived, engineStart, audioStartRequested, audioStarted, firstAudio
        case contextStarted, modeResolutionStarted, modeResolved
        case preparationStarted, preparationFinished, stopReceived, shortcutReleased, releaseTailEnded, wavClosed, speechGate
        case asrStarted, asrFinished, enhancementStarted, enhancementFinished
        case deliveryStarted, destinationReady, clipboardSettled, pasteCommandPosted, deliveryFinished
        case cancelReceived, idle
    }

    enum Outcome: String, Sendable {
        case completed, canceled, failed, skipped, discarded
    }

    struct Event: Equatable, Sendable {
        let phase: Phase
        let outcome: Outcome
        let elapsedNanoseconds: UInt64
    }

    let recordingID: UUID
    let originNanoseconds: UInt64
    private let events = OSAllocatedUnfairLock(initialState: [Phase: Event]())
    private let preRollStart = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "RecordingTiming")

    init(
        recordingID: UUID = UUID(), originNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds,
        requestReceivedNanoseconds: UInt64? = nil
    ) {
        self.recordingID = recordingID
        self.originNanoseconds = originNanoseconds
        if let requestReceivedNanoseconds, requestReceivedNanoseconds > originNanoseconds {
            mark(.shortcutPressed, at: originNanoseconds)
        }
        mark(.requestReceived, at: requestReceivedNanoseconds ?? originNanoseconds)
    }

    // Call only outside the audio render callback. Each phase has one bounded, content-free event.
    func mark(_ phase: Phase, outcome: Outcome = .completed, at timestamp: UInt64? = nil) {
        let now = timestamp ?? DispatchTime.now().uptimeNanoseconds
        guard now >= originNanoseconds else { return }
        let event = Event(phase: phase, outcome: outcome, elapsedNanoseconds: now - originNanoseconds)
        let inserted = events.withLock { events in
            guard events[phase] == nil else { return false }
            events[phase] = event
            return true
        }
        guard inserted else { return }
        logger.debug("recording=\(self.recordingID.uuidString, privacy: .public) phase=\(phase.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) elapsed_ns=\(event.elapsedNanoseconds, privacy: .public)")
    }

    var snapshot: [Event] {
        events.withLock { Array($0.values).sorted { $0.elapsedNanoseconds < $1.elapsedNanoseconds } }
    }

    var preRollStartNanoseconds: UInt64? { preRollStart.withLock { $0 } }

    func recordPreRollStart(at nanoseconds: UInt64) {
        preRollStart.withLock { if $0 == nil { $0 = nanoseconds } }
    }
}
