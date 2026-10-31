import Accelerate
import AVFoundation
import Foundation

struct FeedbackSoundReference: Equatable, Sendable {
    static let sampleRate = 16_000.0
    static let maximumDuration = 3.1
    let samples: [Float]
    private let matchingSamples: [Float]

    init(samples: [Float]) {
        self.samples = samples
        matchingSamples = Self.downsample(samples[...])
    }

    static func load(from url: URL) throws -> Self {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard file.length > 0, Double(file.length) / format.sampleRate <= maximumDuration,
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
            let target = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ),
            let converter = AVAudioConverter(from: format, to: target),
            let output = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: AVAudioFrameCount(ceil(maximumDuration * sampleRate)) + 1024
            )
        else { throw CocoaError(.fileReadCorruptFile) }
        try file.read(into: input)
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Self(samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
    }

    /// Subtract only a near-exact delayed/scaled playback match; unmatched audio stays intact.
    @discardableResult
    func suppress(in audio: inout [Float], expectedOffsetFrames: Int) -> Bool {
        guard !samples.isEmpty, samples.count <= Int(Self.maximumDuration * Self.sampleRate),
            !audio.isEmpty
        else { return false }
        let minimumOverlap = min(1024, min(samples.count, audio.count))
        let lower = max(-samples.count + minimumOverlap, expectedOffsetFrames - 512)
        let upper = min(audio.count - minimumOverlap, expectedOffsetFrames + 4800)
        guard lower <= upper else { return false }
        let coarseStride = 8
        let matchingAudio = Self.downsample(audio.prefix(min(audio.count, max(0, upper) + samples.count)))
        var best: Match?
        matchingSamples.withUnsafeBufferPointer { reference in
            matchingAudio.withUnsafeBufferPointer { capture in
                let first = Int(ceil(Double(lower) / Double(coarseStride)))
                let last = Int(floor(Double(upper) / Double(coarseStride)))
                guard first <= last else { return }
                for offset in first...last {
                    if let match = match(reference: reference, capture: capture, offset: offset),
                        match.explainedEnergy > (best?.explainedEnergy ?? 0)
                    {
                        best = Match(
                            offset: match.offset * coarseStride, gain: match.gain, score: match.score,
                            explainedEnergy: match.explainedEnergy
                        )
                    }
                }
            }
        }
        guard let coarse = best else { return false }
        best = nil
        samples.withUnsafeBufferPointer { reference in
            audio.withUnsafeBufferPointer { capture in
                for offset in max(lower, coarse.offset - coarseStride)...min(upper, coarse.offset + coarseStride) {
                    if let match = match(reference: reference, capture: capture, offset: offset),
                        match.explainedEnergy > (best?.explainedEnergy ?? 0)
                    {
                        best = match
                    }
                }
            }
        }
        // A duration match alone can erase speech; require the actual waveform to explain the input.
        guard let best, best.score >= 0.995 * 0.995 else { return false }
        let captureStart = max(0, best.offset)
        let referenceStart = max(0, -best.offset)
        let count = min(audio.count - captureStart, samples.count - referenceStart)
        for index in 0..<count {
            audio[captureStart + index] -= best.gain * samples[referenceStart + index]
        }
        return true
    }

    private struct Match {
        let offset: Int
        let gain: Float
        let score: Float
        let explainedEnergy: Float
    }

    private func match(
        reference: UnsafeBufferPointer<Float>, capture: UnsafeBufferPointer<Float>, offset: Int
    ) -> Match? {
        let referenceStart = max(0, -offset)
        let captureStart = max(0, offset)
        let count = min(reference.count - referenceStart, capture.count - captureStart)
        guard count > 0 else { return nil }
        let length = vDSP_Length(count)
        let referencePointer = reference.baseAddress! + referenceStart
        let capturePointer = capture.baseAddress! + captureStart
        var product: Float = 0
        var referenceEnergy: Float = 0
        var captureEnergy: Float = 0
        vDSP_dotpr(referencePointer, 1, capturePointer, 1, &product, length)
        vDSP_dotpr(referencePointer, 1, referencePointer, 1, &referenceEnergy, length)
        vDSP_dotpr(capturePointer, 1, capturePointer, 1, &captureEnergy, length)
        guard referenceEnergy > 1e-12, captureEnergy > 1e-12 else { return nil }
        return Match(
            offset: offset, gain: product / referenceEnergy,
            score: product * product / (referenceEnergy * captureEnergy),
            explainedEnergy: product * product / referenceEnergy
        )
    }

    private static func downsample(_ samples: ArraySlice<Float>) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity((samples.count + 7) / 8)
        for start in stride(from: samples.startIndex, to: samples.endIndex, by: 8) {
            let end = min(start + 8, samples.endIndex)
            var sum: Float = 0
            for index in start..<end { sum += samples[index] }
            result.append(sum / Float(end - start))
        }
        return result
    }
}
