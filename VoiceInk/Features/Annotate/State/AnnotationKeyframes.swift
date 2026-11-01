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
        var event: String?
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

    /// The highest-scoring candidates at least `minimumGap` apart, plus coverage of long quiet stretches, in time order.
    static func select(_ candidates: [Candidate], duration: TimeInterval) -> [Candidate] {
        let budget = budget(for: duration)
        var selected: [Candidate] = []
        for candidate in candidates.sorted(by: { ($0.score, -$0.t) > ($1.score, -$1.t) }) where selected.count < budget {
            if selected.allSatisfy({ abs($0.t - candidate.t) >= minimumGap }) { selected.append(candidate) }
        }
        selected.sort { $0.t < $1.t }
        var bounds = [0.0] + selected.map(\.t) + [duration]
        var index = 0
        while selected.count < budget, index < bounds.count - 1 {
            let gap = bounds[index + 1] - bounds[index]
            if gap > coverageGap {
                let middle = bounds[index] + gap / 2
                selected.append(Candidate(t: middle, score: 0, reason: .coverage, event: nil))
                bounds.insert(middle, at: index + 1)
            } else {
                index += 1
            }
        }
        return selected.sorted { $0.t < $1.t }
    }

    /// Words spoken from just before this frame until the next one.
    static func said(at t: TimeInterval, until next: TimeInterval?, in transcript: [TimedTranscriptSegment]) -> String? {
        let words = transcript.flatMap { segment in
            segment.words.isEmpty ? [TimedTranscriptWord(text: segment.text, start: segment.start, end: segment.end)] : segment.words
        }
        let from = t - 1.5
        let spoken = words.filter { $0.end >= from && $0.start < (next ?? .infinity) - 0.25 }.map(\.text)
        let text = spoken.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    static func keyframes(_ manifest: AnnotationManifest, sceneChanges: [AnnotationSceneSampler.Change]) -> [AnnotationKeyframe] {
        let chosen = select(candidates(manifest, sceneChanges: sceneChanges), duration: manifest.duration)
        return chosen.enumerated().map { offset, candidate in
            let next = offset + 1 < chosen.count ? chosen[offset + 1].t : nil
            return AnnotationKeyframe(
                index: offset + 1, t: candidate.t, reason: candidate.reason, event: candidate.event,
                said: said(at: candidate.t, until: next, in: manifest.transcript),
                file: String(format: "frames/frame-%02d.png", offset + 1)
            )
        }
    }
}
