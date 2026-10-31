import AVFoundation
import XCTest

@testable import VoiceInk

@MainActor final class MeetingSummaryTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSummaryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MeetingSummaryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .meetings, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Prompt

    func testTurnsBecomeTimestampedLinesSplitAtWordBoundaries() {
        let long = Array(repeating: "word", count: 200).joined(separator: " ")
        let lines = MeetingSummary.lines([
            MeetingTranscriptEntry(speaker: .you, start: 5, end: 6, text: "Hi there."),
            MeetingTranscriptEntry(speaker: .them, start: 65, end: 200, text: long),
        ])

        XCTAssertEqual(lines.first, "[00:05] \(String(localized: "You")): Hi there.")
        XCTAssertGreaterThan(lines.count, 2)
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.count <= MeetingSummary.lineCharacters && $0.hasPrefix("[01:05] ") })
        XCTAssertEqual(lines.dropFirst().map { $0.split(separator: " ").count - 2 }.reduce(0, +), 200)
    }

    func testShortTranscriptsAreSentWhole() {
        let lines = ["[00:01] You: one", "[00:02] Them: two"]

        XCTAssertEqual(MeetingSummary.excerpt(lines), "[00:01] You: one\n[00:02] Them: two")
    }

    func testLongTranscriptsKeepTheOpeningMiddlePassagesAndTheEndingWithinTheBudget() {
        let lines = (0..<2_000).map { "[\($0)] Them: " + String(repeating: "x", count: 40) }

        let excerpt = MeetingSummary.excerpt(lines)

        XCTAssertLessThanOrEqual(excerpt.count, MeetingSummary.maximumExcerptCharacters)
        XCTAssertTrue(excerpt.hasPrefix(lines[0]))
        XCTAssertTrue(excerpt.hasSuffix(lines[1_999]))
        XCTAssertEqual(excerpt.components(separatedBy: MeetingSummary.gapMarker).count - 1, 7)
        XCTAssertTrue((500..<1_500).contains { excerpt.contains("\n" + lines[$0] + "\n") }, "a middle passage is sampled")
    }

    func testRepliesAreCutToTwoSentencesAndFourHundredCharacters() {
        XCTAssertEqual(
            MeetingSummary.cleaned("Summary: The team picked Friday. Beta ships then.\nAlso a third point."),
            "The team picked Friday. Beta ships then."
        )
        XCTAssertNil(MeetingSummary.cleaned("   \n "))
        let long = MeetingSummary.cleaned(String(repeating: "a", count: 600) + ".")
        XCTAssertEqual(long?.count, MeetingSummary.maximumCharacters)
        XCTAssertTrue(long?.hasSuffix("…") == true)
    }

    func testTheSummaryAppearsAboveTheTranscript() {
        let markdown = MeetingMarkdown.render(
            MeetingManifest(title: "Sync"), turns: [MeetingTranscriptEntry(speaker: .you, start: 0, end: 1, text: "Hi.")],
            summary: "They agreed on Friday."
        )

        let summary = try? XCTUnwrap(markdown.range(of: "## Summary\n\nThey agreed on Friday."))
        let transcript = try? XCTUnwrap(markdown.range(of: "## Transcript"))
        XCTAssertNotNil(summary)
        XCTAssertLessThan(summary!.lowerBound, transcript!.lowerBound)
    }

    // MARK: - Coordinator

    func testSummariesAreAddedOnlyWhenOnAndNeverFailTheTranscript() async throws {
        let summarizer = FakeSummarizer(reply: "They agreed to ship the beta on Friday.")
        let fixture = try makeFixture(summarizer: summarizer)

        let first = try await recordAndTranscribe(fixture)
        XCTAssertEqual(first.summary, "They agreed to ship the beta on Friday.")
        XCTAssertTrue(try String(contentsOfFile: first.transcriptPath!, encoding: .utf8).contains("## Summary\n\nThey agreed"))
        XCTAssertEqual(summarizer.instructions, [MeetingSummary.instructions])
        XCTAssertTrue(summarizer.transcripts.first?.contains("] \(String(localized: "You")): speech") == true)

        summarizer.failure = URLError(.timedOut)
        let failed = try await recordAndTranscribe(fixture)
        XCTAssertEqual(failed.status, .transcribed)
        XCTAssertNil(failed.summary)
        XCTAssertFalse(try String(contentsOfFile: failed.transcriptPath!, encoding: .utf8).contains("## Summary"))

        fixture.summaries.isOn = false
        summarizer.failure = nil
        let off = try await recordAndTranscribe(fixture)
        XCTAssertNil(off.summary)
        XCTAssertEqual(summarizer.transcripts.count, 2)
    }

    func testTheSummarySwitchIsOffByDefaultAndPersists() throws {
        let registered = AppDefaults.registeredValues()
        XCTAssertEqual(registered[MeetingSettings.summarizesKey] as? Bool, false)
        defaults.set(true, forKey: MeetingSettings.summarizesKey)
        let restoredName = "\(suiteName!).restored"
        let restored = UserDefaults(suiteName: restoredName)!
        defer { restored.removePersistentDomain(forName: restoredName) }

        MeetingSettings.Backup.capture(from: defaults).restore(in: restored)

        XCTAssertTrue(MeetingSettings.summarizes(in: restored))
        XCTAssertEqual(try ConfigurationPreferences.capture(from: defaults)[MeetingSettings.summarizesKey], .bool(true))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let recorder: MeetingRecorder
        let coordinator: MeetingTranscriptionCoordinator
        let store: MeetingStore
        let summaries: SummarySwitch
    }

    private func makeFixture(summarizer: FakeSummarizer) throws -> Fixture {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"), movesToTrash: false)
        let devices = MeetingAudioDevices(userDefaults: defaults)
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = store
        dependencies.permission = SummaryGrantedSystemAudio()
        dependencies.makeSystemAudio = { SummaryQuietSystemAudio() }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { FakeMeetingMicrophoneHardware() }) }
        dependencies.isMicrophoneAuthorized = { true }
        dependencies.defaults = defaults
        let recorder = MeetingRecorder(dependencies: dependencies)
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)
        let summaries = SummarySwitch()
        let coordinator = MeetingTranscriptionCoordinator()
        coordinator.configure(
            environment: .init(
                chooseModel: { model }, makeTranscriber: { _ in SpeechTranscriber() },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, isDictating: { false },
                summarizer: { summaries.isOn ? summarizer : nil }, outputFolder: { folder }
            ),
            recorder: recorder
        )
        return Fixture(recorder: recorder, coordinator: coordinator, store: store, summaries: summaries)
    }

    private func recordAndTranscribe(_ fixture: Fixture) async throws -> MeetingManifest {
        try await fixture.recorder.start(title: "Sync")
        let stopped = await fixture.recorder.stop()
        let id = try XCTUnwrap(stopped?.id)
        // The file closes when it goes out of scope, before transcription reads it.
        do {
            let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
            let file = try AVAudioFile(
                forWriting: fixture.store.audioURL(for: id, track: .microphone), settings: format.settings,
                commonFormat: .pcmFormatInt16, interleaved: true
            )
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
            buffer.frameLength = 16_000
            for index in 0..<16_000 { buffer.int16ChannelData![0][index] = Int16(8_000 * sin(Double(index) * 0.2)) }
            try file.write(from: buffer)
        }
        await fixture.coordinator.waitUntilIdle()
        return try fixture.store.load(id: id)
    }
}

@MainActor
private final class SummarySwitch {
    var isOn = true
}

private final class FakeSummarizer: MeetingSummarizing {
    let reply: String
    var failure: Error?
    var transcripts: [String] = []
    var instructions: [String] = []

    init(reply: String) {
        self.reply = reply
    }

    func reply(to transcript: String, instructions: String) async throws -> String {
        transcripts.append(transcript)
        self.instructions.append(instructions)
        if let failure { throw failure }
        return reply
    }
}

private final class SpeechTranscriber: TimedSpeechTranscribing {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        TimedTranscriptSegment.untimed("speech", sampleCount: samples.count)
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}

private final class SummaryGrantedSystemAudio: SystemAudioAuthorizing {
    func status() -> SystemAudioAuthorization { .granted }
    func request() async -> SystemAudioAuthorization { .granted }
}

private final class SummaryQuietSystemAudio: SystemAudioCapturing, @unchecked Sendable {
    var lastDeliveryNanoseconds: UInt64? { DispatchTime.now().uptimeNanoseconds }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {}
    func restart() throws {}
    func stop() -> MeetingTrackCaptureResult { MeetingTrackCaptureResult() }
}
