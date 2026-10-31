import Foundation

/// One speaker's span of a meeting, in seconds since it started.
struct MeetingTranscriptEntry: Codable, Equatable, Sendable {
    enum Speaker: String, Codable, Sendable {
        case you, them

        var label: String {
            switch self {
            case .you: String(localized: "You")
            case .them: String(localized: "Them")
            }
        }

        init(_ track: MeetingManifest.TrackKind) {
            self = track == .microphone ? .you : .them
        }
    }

    var speaker: Speaker
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var words: [TimedTranscriptWord] = []
}

enum MeetingTranscript {
    /// Consecutive entries of one speaker this close together form one turn.
    static let turnGap: TimeInterval = 3

    /// Speech regions grouped into transcription chunks: neighbors closer than `joinGap` share a chunk up to
    /// `maximumLength`, and longer regions are cut at that length.
    static func chunks(
        from regions: [Range<Int>], maximumLength: Int = 30 * 16_000, joinGap: Int = 16_000
    ) -> [Range<Int>] {
        var chunks: [Range<Int>] = []
        for region in regions.sorted(by: { $0.lowerBound < $1.lowerBound }) where !region.isEmpty {
            var start = region.lowerBound
            if let last = chunks.last, start - last.upperBound < joinGap, region.upperBound - last.lowerBound <= maximumLength {
                chunks[chunks.count - 1] = last.lowerBound..<max(last.upperBound, region.upperBound)
                continue
            }
            while region.upperBound - start > maximumLength {
                chunks.append(start..<(start + maximumLength))
                start += maximumLength
            }
            chunks.append(start..<region.upperBound)
        }
        return chunks
    }

    /// Speech regions by level when no voice detector is available: 30 ms frames within `relativeThreshold` dB
    /// of the loudest frame and above `floor` dBFS, padded and joined across short pauses.
    static func energyRegions(
        in samples: [Float], floor: Float = -50, relativeThreshold: Float = 35, padding: Int = 3_200, joinGap: Int = 9_600
    ) -> [Range<Int>] {
        let frame = 480
        guard samples.count >= frame else { return samples.isEmpty ? [] : [0..<samples.count] }
        let levels = stride(from: 0, to: samples.count - frame + 1, by: frame).map { start -> Float in
            var energy: Float = 0
            for index in start..<(start + frame) { energy += samples[index] * samples[index] }
            return 10 * log10(max(energy / Float(frame), 1e-12))
        }
        guard let loudest = levels.max() else { return [] }
        let threshold = max(floor, loudest - relativeThreshold)
        var regions: [Range<Int>] = []
        for (index, level) in levels.enumerated() where level >= threshold {
            let start = max(0, index * frame - padding)
            let end = min(samples.count, (index + 1) * frame + padding)
            if let last = regions.last, start - last.upperBound <= joinGap {
                regions[regions.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                regions.append(start..<end)
            }
        }
        return regions
    }

    /// Drops words whose midpoint falls inside a dictation interval. Segments without words are kept: their
    /// dictated audio was silenced before transcription, and their midpoint says nothing about their words.
    static func removingDictation(
        from segments: [TimedTranscriptSegment], intervals: [MeetingManifest.Interval]
    ) -> [TimedTranscriptSegment] {
        guard !intervals.isEmpty else { return segments }
        func isDictated(_ start: TimeInterval, _ end: TimeInterval) -> Bool {
            let middle = (start + end) / 2
            return intervals.contains { $0.contains(middle) }
        }
        return segments.compactMap { segment in
            guard !segment.words.isEmpty else { return segment }
            let kept = segment.words.filter { !isDictated($0.start, $0.end) }
            guard let first = kept.first, let last = kept.last else { return nil }
            guard kept.count != segment.words.count else { return segment }
            return TimedTranscriptSegment(
                text: kept.map(\.text).joined(separator: " "), start: first.start, end: last.end, words: kept
            )
        }
    }

    /// Both speakers in time order, with consecutive entries of one speaker merged when they are close.
    static func turns(_ entries: [MeetingTranscriptEntry]) -> [MeetingTranscriptEntry] {
        var turns: [MeetingTranscriptEntry] = []
        for entry in entries.sorted(by: { ($0.start, $0.speaker == .them ? 1 : 0) < ($1.start, $1.speaker == .them ? 1 : 0) }) {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speaker == entry.speaker, entry.start - last.end <= turnGap {
                last.text += " " + text
                last.end = max(last.end, entry.end)
                last.words += entry.words
                turns[turns.count - 1] = last
            } else {
                var entry = entry
                entry.text = text
                turns.append(entry)
            }
        }
        return turns
    }
}
