import CoreMedia
import CoreVideo
import Foundation
import os

/// When the recorded screen changes, from Hex's candidate sampling (`keyframes.rs`, MIT): a 64×36 luma thumbnail
/// every 220 ms, compared with the previous one by global and 8×6-block difference. Only change times are kept,
/// so memory stays flat for a 20-minute recording.
final class AnnotationSceneSampler: @unchecked Sendable {
    struct Change: Codable, Equatable, Sendable {
        var t: TimeInterval
        var difference: Float
    }

    static let width = 64
    static let height = 36
    static let interval: TimeInterval = 0.22
    /// Differences above this count as a scene change; small cursor or caret movement stays below it.
    static let threshold: Float = 0.08

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startNanoseconds: UInt64

    private struct State {
        var previous: [Float]?
        var lastSample: TimeInterval = -.infinity
        var changes: [Change] = []
    }

    init(startNanoseconds: UInt64) {
        self.startNanoseconds = startNanoseconds
    }

    var changes: [Change] { state.withLock { $0.changes } }

    /// Called on the capture queue with each frame; ScreenCaptureKit stamps frames on the uptime clock.
    func ingest(_ sampleBuffer: CMSampleBuffer) {
        let presentation = sampleBuffer.presentationTimeStamp
        guard presentation.isValid, let pixels = sampleBuffer.imageBuffer else { return }
        let t = presentation.seconds - Double(startNanoseconds) / 1_000_000_000
        guard state.withLock({ t - $0.lastSample >= Self.interval }) else { return }
        guard let thumbnail = Self.thumbnail(of: pixels) else { return }
        ingest(thumbnail, at: t)
    }

    func ingest(_ thumbnail: [Float], at t: TimeInterval) {
        state.withLock { state in
            state.lastSample = t
            if let previous = state.previous {
                let difference = Self.transitionDifference(previous, thumbnail)
                if difference > Self.threshold { state.changes.append(Change(t: t, difference: difference)) }
            }
            state.previous = thumbnail
        }
    }

    /// Luma 0...1 of a BGRA frame, sampled on a 64×36 grid.
    static func thumbnail(of pixels: CVPixelBuffer) -> [Float]? {
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return nil }
        let frameWidth = CVPixelBufferGetWidth(pixels), frameHeight = CVPixelBufferGetHeight(pixels)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        guard frameWidth > 0, frameHeight > 0 else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var thumbnail = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = min(frameHeight - 1, (2 * y + 1) * frameHeight / (2 * height)) * rowBytes
            for x in 0..<width {
                let pixel = row + min(frameWidth - 1, (2 * x + 1) * frameWidth / (2 * width)) * 4
                let blue = Float(bytes[pixel]), green = Float(bytes[pixel + 1]), red = Float(bytes[pixel + 2])
                thumbnail[y * width + x] = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
            }
        }
        return thumbnail
    }

    /// Hex's `scene_transition_diff`: the global mean difference, or the 4th-highest 8×6 block difference times
    /// 1.4, so a cursor straddling a block corner does not count while a change across four blocks does.
    static func transitionDifference(_ a: [Float], _ b: [Float]) -> Float {
        let global = min(1, zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Float(a.count))
        let columns = 8, rows = 6
        let blockWidth = width / columns, blockHeight = height / rows
        var blocks: [Float] = []
        for blockY in 0..<rows {
            for blockX in 0..<columns {
                var sum: Float = 0
                for y in (blockY * blockHeight)..<((blockY + 1) * blockHeight) {
                    for x in (blockX * blockWidth)..<((blockX + 1) * blockWidth) {
                        sum += abs(a[y * width + x] - b[y * width + x])
                    }
                }
                blocks.append(sum / Float(blockWidth * blockHeight))
            }
        }
        let fourth = blocks.sorted(by: >)[3]
        return max(global, min(1, fourth * 1.4))
    }
}
