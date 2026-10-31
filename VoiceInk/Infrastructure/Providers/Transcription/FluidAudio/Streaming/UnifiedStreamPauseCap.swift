import Foundation

/// Limits what the Parakeet Unified stream hears of each pause to its first 2.5 s and last 0.3 s.
///
/// The stream drops the first words spoken after a pause longer than its 5.6 s left context; the WAV and
/// the batch fallback keep every sample. Adapted from Hex's `PauseCap` and `SpeechFrames::is_quiet`:
/// https://github.com/anomalyco/hex/blob/37c5dcdf81e3438ed4dad0396bd704c6b59d6eeb/src/transcription_engine.rs#L1290-L1377
/// https://github.com/anomalyco/hex/blob/37c5dcdf81e3438ed4dad0396bd704c6b59d6eeb/src/pause_segmenter.rs#L12-L64
struct UnifiedStreamPauseCap {
    static let frameSamples = 320
    /// Longer than a 560 ms chunk plus its 560 ms lookahead, so the words before a pause decode during it.
    static let headSamples = 40_000
    /// Pause audio kept just before speech resumes after a cut.
    static let tailSamples = 4_800

    private var floor = QuietFrameClassifier()
    /// Samples not yet a whole 20 ms frame.
    private var frame: [Float] = []
    /// Quiet samples since the last frame above the noise floor.
    private var pause = 0
    /// The newest pause samples past the head, released if speech resumes.
    private var tail: [Float] = []
    private(set) var droppedSamples = 0

    init() {
        frame.reserveCapacity(Self.frameSamples)
        tail.reserveCapacity(Self.tailSamples + Self.frameSamples)
    }

    /// Returns the samples the stream should hear, in order.
    mutating func feed(_ samples: [Float]) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(samples.count + tail.count)
        var index = samples.startIndex
        while index < samples.endIndex {
            let take = min(samples.endIndex - index, Self.frameSamples - frame.count)
            frame.append(contentsOf: samples[index..<index + take])
            index += take
            if frame.count == Self.frameSamples { completeFrame(into: &output) }
        }
        return output
    }

    /// Returns the final partial frame when the recording does not end in a long pause; a trailing pause keeps
    /// only its head.
    mutating func finish() -> [Float] {
        defer {
            droppedSamples += tail.count
            tail.removeAll()
            frame.removeAll()
        }
        guard pause <= Self.headSamples else {
            droppedSamples += frame.count
            return []
        }
        return frame
    }

    private mutating func completeFrame(into output: inout [Float]) {
        defer { frame.removeAll(keepingCapacity: true) }
        // Only audio at the noise floor counts as pause, so quiet speech over steady noise is never cut.
        guard floor.isQuiet(frame) else {
            output.append(contentsOf: tail)
            tail.removeAll(keepingCapacity: true)
            pause = 0
            output.append(contentsOf: frame)
            return
        }
        pause += frame.count
        guard pause > Self.headSamples else {
            output.append(contentsOf: frame)
            return
        }
        tail.append(contentsOf: frame)
        let overflow = tail.count - Self.tailSamples
        if overflow > 0 {
            tail.removeFirst(overflow)
            droppedSamples += overflow
        }
    }
}

/// Classifies 20 ms frames of 16 kHz audio against an adaptive noise floor. The floor follows a quieter frame
/// at once and rises about 3 dB per second, so speech between word gaps cannot drag it up to the speech level.
struct QuietFrameClassifier {
    /// How far above the floor a frame may sit and still count as quiet.
    static let quietMarginDB: Float = 4
    static let minimumSpeechDB: Float = -55
    static let lowestFloorDB: Float = -90
    static let floorRiseDBPerFrame: Float = 0.06

    private var floorDB: Float?

    /// Whether `frame` sits within 4 dB of the noise floor or below -55 dBFS.
    mutating func isQuiet(_ frame: [Float]) -> Bool {
        let energy = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(1, frame.count))
        let levelDB = energy.isFinite ? 10 * log10(max(energy, 1e-18)) : 0
        let floorDB: Float
        if let previous = self.floorDB, levelDB >= previous {
            floorDB = previous + Self.floorRiseDBPerFrame
        } else {
            floorDB = max(levelDB, Self.lowestFloorDB)
        }
        self.floorDB = floorDB
        return levelDB <= max(floorDB + Self.quietMarginDB, Self.minimumSpeechDB)
    }
}
