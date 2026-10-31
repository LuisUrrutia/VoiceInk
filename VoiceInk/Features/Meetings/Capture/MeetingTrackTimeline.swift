import Foundation

/// Maps a track's 16 kHz frames to seconds since the meeting started. Anchors absorb capture gaps, device
/// switches and clock drift, so the two tracks stay aligned without padding either file with silence.
struct MeetingTrackTimeline: Codable, Equatable, Sendable {
    struct Anchor: Codable, Equatable, Sendable {
        var frame: Int
        var time: TimeInterval
    }

    static let sampleRate: Double = 16_000
    /// A new anchor at least this often keeps drift between two anchors small.
    static let anchorInterval: TimeInterval = 5
    /// Larger differences from the expected time are gaps or jumps and start a new anchor at once.
    static let discontinuityTolerance: TimeInterval = 0.25

    private(set) var anchors: [Anchor] = []

    /// Records that `frame` was captured `time` seconds after the meeting started.
    mutating func record(frame: Int, at time: TimeInterval) {
        guard frame >= 0, time.isFinite else { return }
        guard let last = anchors.last else {
            anchors.append(Anchor(frame: frame, time: time))
            return
        }
        guard frame >= last.frame else { return }
        let expected = last.time + Double(frame - last.frame) / Self.sampleRate
        if abs(time - expected) > Self.discontinuityTolerance || time - last.time >= Self.anchorInterval {
            anchors.append(Anchor(frame: frame, time: max(time, last.time)))
        }
    }

    /// Seconds since the meeting started for `frame`, extrapolating from the last anchor at or before it.
    func time(forFrame frame: Int) -> TimeInterval {
        guard let first = anchors.first else { return Double(frame) / Self.sampleRate }
        let anchor = anchors.last(where: { $0.frame <= frame }) ?? first
        return max(0, anchor.time + Double(frame - anchor.frame) / Self.sampleRate)
    }

    func time(forSeconds offset: TimeInterval) -> TimeInterval {
        time(forFrame: Int((offset * Self.sampleRate).rounded()))
    }
}
