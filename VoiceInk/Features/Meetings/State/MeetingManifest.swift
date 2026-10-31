import Foundation

/// The persisted record of one meeting, written when it starts and after every state change.
struct MeetingManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1
    static let fileName = "meeting.json"

    enum Status: String, Codable, Sendable {
        case recording, recorded, transcribing, transcribed, interrupted, failed
    }

    enum TrackKind: String, Codable, CaseIterable, Sendable {
        case system, microphone

        var fileName: String { "\(rawValue).wav" }
    }

    struct Track: Codable, Equatable, Sendable {
        var kind: TrackKind
        var timeline = MeetingTrackTimeline()
        var droppedBuffers = 0
        /// False when the track never delivered a level above digital silence, such as a denied system tap.
        var heardSignal = false
        var failure: String?
    }

    struct Interval: Codable, Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval

        func contains(_ time: TimeInterval) -> Bool { time >= start && time <= end }
    }

    var version = Self.currentVersion
    var id: UUID
    var createdAt: Date
    var status: Status
    var title: String
    /// `MeetingProvider.id` of the detected call, if any.
    var provider: String?
    var duration: TimeInterval = 0
    var tracks: [Track]
    /// Dictations captured during the meeting, in seconds since it started; their words are not transcribed as You.
    var dictationIntervals: [Interval] = []
    /// Markdown file written for this meeting.
    var transcriptPath: String?
    /// Microphone utterances the last transcription dropped as speaker echo.
    var echoSuppressedUtterances: Int?
    var failure: String?

    init(id: UUID = UUID(), createdAt: Date = Date(), title: String, provider: String? = nil) {
        self.id = id
        // Whole seconds survive the manifest's ISO 8601 dates unchanged.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
        self.title = title
        self.provider = provider
        status = .recording
        tracks = TrackKind.allCases.map { Track(kind: $0) }
    }

    func track(_ kind: TrackKind) -> Track? { tracks.first { $0.kind == kind } }

    mutating func updateTrack(_ kind: TrackKind, _ update: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.kind == kind }) else { return }
        update(&tracks[index])
    }
}
