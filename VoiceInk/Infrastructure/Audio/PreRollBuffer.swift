import Foundation

/// Bounded idle capture history in the hardware format, owned by the recorder's processing queue.
/// Released frames are zeroed so audio older than the retained window does not stay in memory.
struct PreRollBuffer {
    static let windowNanoseconds: UInt64 = 450_000_000
    /// A press awaiting its recording retains audio from one window before it, for at most this long.
    static let pendingPressLimitNanoseconds: UInt64 = 2_000_000_000

    let sampleRate: Double
    let channelCount: Int
    let capacityFrames: Int
    private var storage: [Float]
    private var frameEnds: [UInt64]
    private var oldestFrame = 0
    private(set) var frameCount = 0
    /// Monotonic uptime at the end of the newest buffered frame.
    private(set) var newestFrameEndNanoseconds: UInt64 = 0

    init(sampleRate: Double, channelCount: Int) {
        precondition(sampleRate > 0 && channelCount > 0)
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        let retained = Double(Self.windowNanoseconds + Self.pendingPressLimitNanoseconds) / 1_000_000_000
        capacityFrames = Int((retained * sampleRate).rounded(.up))
        storage = [Float](repeating: 0, count: capacityFrames * channelCount)
        frameEnds = [UInt64](repeating: 0, count: capacityFrames)
    }

    var duration: TimeInterval { Double(frameCount) / sampleRate }

    /// Appends interleaved frames ending at `endNanoseconds`, then drops audio older than the retained window.
    mutating func append(
        _ samples: UnsafeBufferPointer<Float>, endNanoseconds: UInt64, pendingPressNanoseconds: UInt64?
    ) {
        let incomingFrames = samples.count / channelCount
        let skippedFrames = max(0, incomingFrames - capacityFrames)
        for frame in skippedFrames..<incomingFrames {
            if frameCount == capacityFrames {
                oldestFrame = (oldestFrame + 1) % capacityFrames
                frameCount -= 1
            }
            let destination = ((oldestFrame + frameCount) % capacityFrames) * channelCount
            let framesAfter = incomingFrames - frame - 1
            let remainingNanoseconds = UInt64((Double(framesAfter) * 1_000_000_000 / sampleRate).rounded())
            frameEnds[(oldestFrame + frameCount) % capacityFrames] = endNanoseconds.subtractingClamped(remainingNanoseconds)
            for channel in 0..<channelCount {
                storage[destination + channel] = samples[frame * channelCount + channel]
            }
            frameCount += 1
        }
        newestFrameEndNanoseconds = endNanoseconds
        retainFrames(after: retentionStart(pendingPressNanoseconds: pendingPressNanoseconds))
    }

    /// Returns interleaved audio from one window before the press through the newest frame, and empties the buffer.
    mutating func take(pressNanoseconds: UInt64) -> [Float] {
        retainFrames(after: pressNanoseconds.subtractingClamped(Self.windowNanoseconds))
        var result = [Float]()
        result.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            let source = ((oldestFrame + frame) % capacityFrames) * channelCount
            result.append(contentsOf: storage[source..<source + channelCount])
        }
        removeAll()
        return result
    }

    mutating func removeAll() {
        oldestFrame = 0
        frameCount = 0
        storage.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        frameEnds.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
    }

    private func retentionStart(pendingPressNanoseconds: UInt64?) -> UInt64 {
        if let press = pendingPressNanoseconds,
            newestFrameEndNanoseconds.subtractingClamped(press) <= Self.pendingPressLimitNanoseconds
        {
            return press.subtractingClamped(Self.windowNanoseconds)
        }
        return newestFrameEndNanoseconds.subtractingClamped(Self.windowNanoseconds)
    }

    private mutating func retainFrames(after start: UInt64) {
        var droppedFrames = 0
        while droppedFrames < frameCount,
            frameEnds[(oldestFrame + droppedFrames) % capacityFrames] <= start
        {
            droppedFrames += 1
        }
        guard droppedFrames > 0 else { return }
        for frame in 0..<droppedFrames {
            let index = ((oldestFrame + frame) % capacityFrames) * channelCount
            frameEnds[(oldestFrame + frame) % capacityFrames] = 0
            storage.withUnsafeMutableBufferPointer { samples in
                samples[index..<index + channelCount].update(repeating: 0)
            }
        }
        oldestFrame = (oldestFrame + droppedFrames) % capacityFrames
        frameCount -= droppedFrames
    }
}

private extension UInt64 {
    func subtractingClamped(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
