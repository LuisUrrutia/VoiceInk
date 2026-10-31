import Foundation

struct TimedTranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Text with its position in seconds. `words` is empty when the model reports only segment times.
struct TimedTranscriptSegment: Codable, Equatable, Sendable {
    var text: String
    var start: TimeInterval
    var end: TimeInterval
    var words: [TimedTranscriptWord] = []

    func shifted(by offset: TimeInterval) -> TimedTranscriptSegment {
        TimedTranscriptSegment(
            text: text, start: start + offset, end: end + offset,
            words: words.map { TimedTranscriptWord(text: $0.text, start: $0.start + offset, end: $0.end + offset) }
        )
    }
}

/// Local transcription that keeps timing: segments and, when the model reports them, words, in seconds from
/// the first sample.
protocol TimedSpeechTranscribing: AnyObject {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment]
    /// Speech regions as sample ranges, or nil when voice detection is off or unavailable.
    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]?
    func releaseResources() async
}

enum TimedTranscriptionError: LocalizedError {
    case unsupportedModel

    var errorDescription: String? {
        String(localized: "Meetings needs a downloaded local model, such as Parakeet or Whisper.")
    }
}

extension TimedTranscriptSegment {
    /// One segment for models that report no timing, spanning the transcribed samples.
    static func untimed(_ text: String, sampleCount: Int) -> [TimedTranscriptSegment] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return [TimedTranscriptSegment(text: text, start: 0, end: Double(sampleCount) / 16_000)]
    }

    /// Groups words into sentence-sized segments on a pause longer than `pause` or a sentence end.
    static func grouping(_ words: [TimedTranscriptWord], pause: TimeInterval = 0.8) -> [TimedTranscriptSegment] {
        var segments: [TimedTranscriptSegment] = []
        var current: [TimedTranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            segments.append(TimedTranscriptSegment(
                text: current.map(\.text).joined(separator: " "), start: first.start, end: last.end, words: current
            ))
            current = []
        }
        for word in words where !word.text.isEmpty {
            if let last = current.last, word.start - last.end > pause { flush() }
            current.append(word)
            if let final = word.text.last, ".!?".contains(final) { flush() }
        }
        flush()
        return segments
    }
}
