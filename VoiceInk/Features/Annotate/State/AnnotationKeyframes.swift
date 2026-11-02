import Foundation

/// A moment chosen to show an agent, with the image it was rendered to.
struct AnnotationKeyframe: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        case initial, mark, click, speech, sceneChange, coverage
    }

    var index: Int
    var t: TimeInterval
    var reason: Reason
    /// What happened there: a mark's description, a click or the screen changing.
    var event: String?
    /// Narration spoken around this frame.
    var said: String?
    var file: String?
}

/// Which moments become keyframes, after Hex's selection (`keyframes.rs` and `keyframe_budget`, MIT): marks,
/// clicks, pointing words and scene changes compete by score, kept 0.75 s apart, within a budget that grows with
/// length. Hex's per-screen mark grouping, cue novelty and auto-crop are not ported.
enum AnnotationKeyframes {
    static let baseBudget = 6
    static let maximumBudget = 12
    static let minimumGap: TimeInterval = 0.75
    /// Clicks are shown a moment later, with their result rather than the mouse-down state.
    static let clickDelay: TimeInterval = 0.25
    /// Stretches without a keyframe this long get one in their middle.
    static let coverageGap: TimeInterval = 35

    /// Hex's `keyframe_budget`: 6 up to 40 s, then one more per 20 s, up to 12 at 2:20.
    static func budget(for duration: TimeInterval) -> Int {
        min(baseBudget + max(0, Int(duration * 1_000) - 20_000) / 20_000, maximumBudget)
    }

    /// Words that point at the screen and their Hex scores; the strong ones are deliberate cues.
    static let cues: [String: Double] = [
        "now": 58, "here": 56, "look": 58, "watch": 58,
        "see": 44, "there": 44, "this": 44, "these": 44, "that": 42, "those": 42,
    ]

    struct Candidate: Equatable {
        var t: TimeInterval
        var score: Double
        var reason: AnnotationKeyframe.Reason
        var event: String? = nil
    }

    static func candidates(_ manifest: AnnotationManifest, sceneChanges: [AnnotationSceneSampler.Change]) -> [Candidate] {
        let duration = manifest.duration
        func clamp(_ t: TimeInterval) -> TimeInterval { min(max(t, 0), max(0, duration - 0.05)) }
        var candidates = [Candidate(t: clamp(0.5), score: 30, reason: .initial, event: nil)]
        candidates += manifest.marks.map { Candidate(t: clamp($0.end + 0.05), score: 100, reason: .mark, event: $0.description) }
        candidates += manifest.events.filter { $0.kind != .scroll }.map { event in
            let verb = event.kind == .click ? "clicked" : "right-clicked"
            return Candidate(
                t: clamp(event.t + clickDelay), score: 60, reason: .click,
                event: String(format: "\(verb) at x %.2f, y %.2f", event.x, event.y)
            )
        }
        candidates += manifest.transcript.flatMap(\.words).compactMap { word in
            let token = word.text.trimmingCharacters(in: .alphanumerics.inverted).lowercased()
            return cues[token].map { Candidate(t: clamp(word.start), score: $0, reason: .speech, event: nil) }
        }
        candidates += sceneChanges.map {
            Candidate(t: clamp($0.t), score: 40 + 40 * Double($0.difference), reason: .sceneChange, event: "the screen changed")
        }
        return candidates
    }

    /// Keyframes in time order: first the best candidate of each stretch of at most `coverageGap` (a coverage frame
    /// where a stretch has none), with stretches widened to fit the budget, then the highest-scoring rest. All stay
    /// `minimumGap` apart, so an early burst cannot leave the rest of a long annotation without images.
    static func select(_ candidates: [Candidate], duration: TimeInterval) -> [Candidate] {
        let budget = budget(for: duration)
        let windowCount = min(budget, max(1, Int((duration / coverageGap).rounded(.up))))
        let windowLength = max(duration, 0.001) / Double(windowCount)
        var selected: [Candidate] = []
        func fits(_ candidate: Candidate) -> Bool { selected.allSatisfy { abs($0.t - candidate.t) >= minimumGap } }
        let ranked = candidates.sorted { ($0.score, -$0.t) > ($1.score, -$1.t) }
        for window in 0..<windowCount {
            let lower = Double(window) * windowLength
            let upper = window == windowCount - 1 ? .infinity : lower + windowLength
            if let best = ranked.first(where: { $0.t >= lower && $0.t < upper && fits($0) }) {
                selected.append(best)
            } else {
                let coverage = Candidate(t: min(lower + windowLength / 2, max(0, duration - 0.05)), score: 0, reason: .coverage)
                if fits(coverage) { selected.append(coverage) }
            }
        }
        for candidate in ranked where selected.count < budget && !selected.contains(candidate) && fits(candidate) {
            selected.append(candidate)
        }
        return selected.sorted { $0.t < $1.t }
    }

    /// What was said at each keyframe, each word given to one frame only: a frame's narration runs from up to 1.5 s
    /// before it (half-way to the previous frame when that is closer) to where the next frame's begins. The first
    /// frame also takes everything said before it.
    static func said(at times: [TimeInterval], in transcript: [TimedTranscriptSegment]) -> [String?] {
        let words = transcript.flatMap { segment in
            segment.words.isEmpty ? [TimedTranscriptWord(text: segment.text, start: segment.start, end: segment.end)] : segment.words
        }
        let boundaries = times.indices.map { index -> TimeInterval in
            guard index > 0 else { return -.infinity }
            return times[index] - min(1.5, (times[index] - times[index - 1]) / 2)
        }
        return times.indices.map { index in
            let lower = boundaries[index]
            let upper = index + 1 < boundaries.count ? boundaries[index + 1] : .infinity
            let text = words.filter { $0.start >= lower && $0.start < upper }.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : text
        }
    }

    static func keyframes(_ manifest: AnnotationManifest, sceneChanges: [AnnotationSceneSampler.Change]) -> [AnnotationKeyframe] {
        let chosen = select(candidates(manifest, sceneChanges: sceneChanges), duration: manifest.duration)
        let narration = said(at: chosen.map(\.t), in: manifest.transcript)
        return chosen.enumerated().map { offset, candidate in
            AnnotationKeyframe(
                index: offset + 1, t: candidate.t, reason: candidate.reason, event: candidate.event,
                said: narration[offset],
                file: String(format: "frames/frame-%02d.png", offset + 1)
            )
        }
    }
}
