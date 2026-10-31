import Foundation

/// Capture that continues after a shortcut release so a word still being spoken is kept.
struct RecordingReleaseTail: Equatable, Sendable {
    static let durationNanoseconds: UInt64 = 200_000_000
    // A stalled or failed stream finishes with the audio that arrived.
    static let stallGraceNanoseconds: UInt64 = 100_000_000
    static let pollIntervalNanoseconds: UInt64 = 5_000_000

    struct Outcome: Equatable, Sendable {
        enum Reason: Equatable, Sendable {
            case captured, stalled, endedEarly
        }

        let reason: Reason
        let endedAtNanoseconds: UInt64
    }

    /// Monotonic uptime of the release as handled; never earlier than the physical release.
    let releasedAtNanoseconds: UInt64

    var captureDeadlineNanoseconds: UInt64 { releasedAtNanoseconds + Self.durationNanoseconds }
    var waitDeadlineNanoseconds: UInt64 { captureDeadlineNanoseconds + Self.stallGraceNanoseconds }

    static func now() -> RecordingReleaseTail {
        RecordingReleaseTail(releasedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }

    @MainActor
    func waitForCapture(
        capturedThrough: () -> UInt64?,
        shouldEndEarly: () -> Bool,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) async -> Outcome {
        while true {
            let current = now()
            if shouldEndEarly() || Task.isCancelled {
                return Outcome(reason: .endedEarly, endedAtNanoseconds: current)
            }
            if let through = capturedThrough(), through >= captureDeadlineNanoseconds {
                return Outcome(reason: .captured, endedAtNanoseconds: current)
            }
            guard current < waitDeadlineNanoseconds else {
                return Outcome(reason: .stalled, endedAtNanoseconds: current)
            }
            do {
                try await sleep(min(Self.pollIntervalNanoseconds, waitDeadlineNanoseconds - current))
            } catch {
                return Outcome(reason: .endedEarly, endedAtNanoseconds: now())
            }
        }
    }
}
