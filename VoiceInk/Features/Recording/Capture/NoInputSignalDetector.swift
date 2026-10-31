import CoreAudio
import Foundation

/// Recognizes a recording input that delivers no usable level: a dead, muted or wrong microphone.
/// Adapted from Hex's microphone warning (https://github.com/anomalyco/hex, MIT): 1.5 s without a
/// heard peak shows it, and the next heard peak hides it.
struct NoInputSignalDetector {
    /// One PCM16 step. Quieter input is lost in the recording; a working microphone's room noise
    /// measured at least 23 dB above it, so a quiet room is not mistaken for a dead input.
    static let heardPeakDBFS: Float = -90
    static let quietDurationNanoseconds: UInt64 = 1_500_000_000

    private let quietDurationNanoseconds: UInt64
    private(set) var isWarning = false
    private var inputID: AudioDeviceID?
    private var quietSince: UInt64
    private var hasWarned = false
    private var lastCapturedThrough: UInt64?

    init(startedAt now: UInt64, quietDurationNanoseconds: UInt64 = Self.quietDurationNanoseconds) {
        self.quietDurationNanoseconds = quietDurationNanoseconds
        quietSince = now
    }

    /// Takes the latest meter reading. A buffer counts only when `capturedThrough` advanced since the
    /// previous reading, so a stalled input reads as silent. Warns at most once per input; a new
    /// input starts a fresh evaluation.
    mutating func observe(
        peakDBFS: Float, capturedThrough: UInt64?, inputID: AudioDeviceID?, at now: UInt64
    ) {
        if inputID != self.inputID {
            self.inputID = inputID
            quietSince = now
            hasWarned = false
            isWarning = false
        }
        let delivered = capturedThrough != nil && capturedThrough != lastCapturedThrough
        lastCapturedThrough = capturedThrough
        if delivered && peakDBFS >= Self.heardPeakDBFS {
            quietSince = now
            isWarning = false
        } else if !hasWarned, now >= quietSince + quietDurationNanoseconds {
            hasWarned = true
            isWarning = true
        }
    }
}
