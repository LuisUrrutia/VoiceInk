import Foundation

struct SpeechTimeline {
    struct Span {
        let speechStart: Int
        let originalStart: Int
        let length: Int
    }
    let spans: [Span]
    let originalCount: Int

    init(ranges: [Range<Int>], originalCount: Int) throws {
        var previousEnd = 0
        var speechStart = 0
        var spans: [Span] = []
        for range in ranges {
            guard range.lowerBound >= previousEnd, range.upperBound <= originalCount, !range.isEmpty else {
                throw CLIError.message("Invalid speech intervals")
            }
            spans.append(Span(speechStart: speechStart, originalStart: range.lowerBound, length: range.count))
            speechStart += range.count
            previousEnd = range.upperBound
        }
        self.spans = spans
        self.originalCount = originalCount
    }

    // At a join, starts use the next interval and ends use the preceding interval.
    func originalTime(_ time: Double, isEnd: Bool) -> Double {
        guard time.isFinite, let last = spans.last else { return 0 }
        let position = max(0, min(time * 16_000, Double(last.speechStart + last.length)))
        let chosen = spans.first {
            isEnd ? position <= Double($0.speechStart + $0.length) : position < Double($0.speechStart + $0.length)
        } ?? last
        return Double(min(originalCount, chosen.originalStart)) / 16_000
            + min(max(position - Double(chosen.speechStart), 0), Double(chosen.length)) / 16_000
    }
    var speechCount: Int { spans.reduce(0) { $0 + $1.length } }
}

struct TimedSegment: Codable, Equatable {
    let start: Double
    let end: Double
    let text: String
}

struct Transcript: Codable {
    let text: String
    let segments: [TimedSegment]
    let duration: Double
    let speechDuration: Double
    let vadApplied: Bool

    func render(_ format: OutputFormat) throws -> Data {
        switch format {
        case .txt: return Data((text + "\n").utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(self)
            data.append(10)
            return data
        case .srt:
            var previousEnd = 0
            let cues = segments.compactMap { segment -> (Int, Int, String)? in
                let start = max(previousEnd, Int((max(0, segment.start) * 1000).rounded()))
                let end = max(start, Int((min(duration, segment.end) * 1000).rounded()))
                guard end > start, !segment.text.isEmpty else { return nil }
                previousEnd = end
                return (start, end, segment.text)
            }
            let text = cues.enumerated().map { index, cue in
                "\(index + 1)\n\(Self.timestamp(cue.0)) --> \(Self.timestamp(cue.1))\n\(cue.2)\n"
            }.joined(separator: "\n")
            return Data(text.utf8)
        }
    }

    static func timestamp(_ milliseconds: Int) -> String {
        let value = max(0, milliseconds)
        return String(format: "%02d:%02d:%02d,%03d", value / 3_600_000,
                      value / 60_000 % 60, value / 1000 % 60, value % 1000)
    }
}
