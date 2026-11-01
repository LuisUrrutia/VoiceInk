import CoreGraphics
import Foundation

extension LabsFeature {
    static let annotate = LabsFeature(
        id: "annotate",
        title: "Annotate",
        summary: "Record your screen while you narrate, then copy a timestamped bundle for an AI agent."
    )
}

/// `annotation.json`, the bundle's machine-readable record. Times are seconds since the annotation started;
/// screen positions are normalized to the recorded display (0...1, origin top-left).
struct AnnotationManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentVersion = 1
    static let fileName = "annotation.json"
    static let videoFileName = "recording.mp4"
    static let narrationFileName = "narration.wav"
    static let summaryFileName = "summary.md"
    static let contactSheetFileName = "contact-sheet.png"
    static let framesDirectoryName = "frames"

    enum Status: String, Codable, Sendable {
        case recording, processing, ready, failed
    }

    struct Display: Codable, Equatable, Sendable {
        var id: UInt32
        var width: Int
        var height: Int
        var scale: Double
    }

    var version = Self.currentVersion
    var id: UUID
    var createdAt: Date
    var status: Status = .recording
    var duration: TimeInterval = 0
    var display: Display?
    /// Where the video's first frame lies on the annotation timeline.
    var videoOffset: TimeInterval?
    var narrationTimeline = MeetingTrackTimeline()
    var transcript: [TimedTranscriptSegment] = []
    var transcriptModel: String?
    var failure: String?
    /// The narration capture failed; its audio, and so its transcript, may be incomplete.
    var narrationFailure: String?
    var strokes: [AnnotationStroke] = []
    var marks: [AnnotationMark] = []
    var events: [AnnotationEvent] = []
    var sceneChanges: [AnnotationSceneSampler.Change] = []
    var keyframes: [AnnotationKeyframe] = []
    /// `contact-sheet.png`, when keyframes were rendered.
    var contactSheet: String?
    /// The last configured agent command run for this annotation.
    var agentRun: AnnotationAgentRun?
    /// The movie and narration were removed by retention; the images and text remain.
    var mediaRemoved = false

    private enum CodingKeys: String, CodingKey {
        case version, id, createdAt, status, duration, display, videoOffset, narrationTimeline, transcript, transcriptModel,
            failure, narrationFailure, strokes, marks, events, sceneChanges, keyframes, contactSheet, agentRun, mediaRemoved
    }

    /// Fields added after the first version default when an older manifest lacks them.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(Status.self, forKey: .status)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        display = try container.decodeIfPresent(Display.self, forKey: .display)
        videoOffset = try container.decodeIfPresent(TimeInterval.self, forKey: .videoOffset)
        narrationTimeline = try container.decodeIfPresent(MeetingTrackTimeline.self, forKey: .narrationTimeline) ?? MeetingTrackTimeline()
        transcript = try container.decodeIfPresent([TimedTranscriptSegment].self, forKey: .transcript) ?? []
        transcriptModel = try container.decodeIfPresent(String.self, forKey: .transcriptModel)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        narrationFailure = try container.decodeIfPresent(String.self, forKey: .narrationFailure)
        strokes = try container.decodeIfPresent([AnnotationStroke].self, forKey: .strokes) ?? []
        marks = try container.decodeIfPresent([AnnotationMark].self, forKey: .marks) ?? []
        events = try container.decodeIfPresent([AnnotationEvent].self, forKey: .events) ?? []
        sceneChanges = try container.decodeIfPresent([AnnotationSceneSampler.Change].self, forKey: .sceneChanges) ?? []
        keyframes = try container.decodeIfPresent([AnnotationKeyframe].self, forKey: .keyframes) ?? []
        contactSheet = try container.decodeIfPresent(String.self, forKey: .contactSheet)
        agentRun = try container.decodeIfPresent(AnnotationAgentRun.self, forKey: .agentRun)
        mediaRemoved = try container.decodeIfPresent(Bool.self, forKey: .mediaRemoved) ?? false
    }

    init(id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        // Whole seconds survive ISO 8601 dates unchanged.
        self.createdAt = Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down))
    }
}

/// `Annotations/<id>/` folders in the build's isolated persistence directory: owner-only, manifests replaced
/// atomically.
struct AnnotationStore: Sendable {
    let rootURL: URL
    var movesToTrash = true

    static let `default` = AnnotationStore(
        rootURL: VoiceInkPersistence.directoryURL.appendingPathComponent("Annotations", isDirectory: true)
    )

    func directory(for id: UUID) -> URL { rootURL.appendingPathComponent(id.uuidString, isDirectory: true) }

    func url(for id: UUID, file: String) -> URL { directory(for: id).appendingPathComponent(file) }

    func createDirectory(for id: UUID) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fileManager.createDirectory(at: directory(for: id), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }

    func save(_ manifest: AnnotationManifest) throws {
        let url = url(for: manifest.id, file: AnnotationManifest.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: url, options: [.atomic])
        protect(url)
    }

    func load(id: UUID) throws -> AnnotationManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnnotationManifest.self, from: Data(contentsOf: url(for: id, file: AnnotationManifest.fileName)))
    }

    func loadAll() -> [AnnotationManifest] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap { try? load(id: $0) } }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) throws {
        let directory = directory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        if movesToTrash {
            try FileManager.default.trashItem(at: directory, resultingItemURL: nil)
        } else {
            try FileManager.default.removeItem(at: directory)
        }
    }

    func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
