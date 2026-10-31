import AVFoundation
import IOKit.pwr_mgt
import XCTest
import os

@testable import VoiceInk

@MainActor final class MeetingTranscriptTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingTranscriptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "MeetingTranscriptTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .meetings, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Chunks and regions

    func testChunksJoinNearbySpeechAndCutLongRegions() {
        let second = 16_000
        let chunks = MeetingTranscript.chunks(
            from: [0..<second, (second + 8_000)..<(2 * second), (5 * second)..<(70 * second)], maximumLength: 30 * second
        )

        XCTAssertEqual(chunks, [0..<(2 * second), (5 * second)..<(35 * second), (35 * second)..<(65 * second), (65 * second)..<(70 * second)])
    }

    func testEnergyRegionsFindSpeechAboveTheFloorWithPadding() {
        var samples = [Float](repeating: 0, count: 48_000)
        for index in 16_000..<17_600 { samples[index] = 0.2 * sin(Float(index) * 0.3) }

        let regions = MeetingTranscript.energyRegions(in: samples)

        XCTAssertEqual(regions.count, 1)
        XCTAssertLessThanOrEqual(regions[0].lowerBound, 16_000 - 3_000)
        XCTAssertGreaterThanOrEqual(regions[0].upperBound, 17_600 + 3_000)
        XCTAssertTrue(MeetingTranscript.energyRegions(in: [Float](repeating: 0.0001, count: 48_000)).isEmpty)
    }

    func testGroupingSplitsWordsAtPausesAndSentenceEnds() {
        let words = [("Hello", 0.0, 0.3), ("there.", 0.35, 0.6), ("Next", 0.7, 0.9), ("one", 2.0, 2.2)].map {
            TimedTranscriptWord(text: $0.0, start: $0.1, end: $0.2)
        }

        let segments = TimedTranscriptSegment.grouping(words)

        XCTAssertEqual(segments.map(\.text), ["Hello there.", "Next", "one"])
        XCTAssertEqual(segments.map(\.start), [0, 0.7, 2.0])
    }

    // MARK: - Dictation and turns

    func testDictatedWordsAreRemovedFromYouButOtherWordsStay() {
        let words = [("I", 0.0, 0.2), ("think", 0.3, 0.5), ("Hey", 5.0, 5.2), ("VoiceInk", 5.3, 5.8), ("so", 9.0, 9.2)].map {
            TimedTranscriptWord(text: $0.0, start: $0.1, end: $0.2)
        }
        let segments = [
            TimedTranscriptSegment(text: "I think Hey VoiceInk so", start: 0, end: 9.2, words: words),
            TimedTranscriptSegment(text: "untimed dictation", start: 5.1, end: 5.9),
        ]

        let kept = MeetingTranscript.removingDictation(from: segments, intervals: [.init(start: 4.9, end: 6)])

        // A wordless segment is kept: its dictated audio is silenced before transcription instead.
        XCTAssertEqual(kept.map(\.text), ["I think so", "untimed dictation"])
        XCTAssertEqual(kept.first?.end, 9.2)
    }

    func testDictatedMicrophoneAudioIsSilencedBeforeTranscriptionAcrossAGap() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0)
        timeline.record(frame: 32_000, at: 5)
        var samples = [Float](repeating: 0.5, count: 64_000)

        MeetingTranscriber.silence([.init(start: 1, end: 1.5), .init(start: 3, end: 5.5)], in: &samples, timeline: timeline)

        XCTAssertEqual(timeline.frame(forTime: 3), 32_000)
        XCTAssertTrue(samples[16_000..<24_000].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[24_000..<32_000].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(samples[32_000..<40_000].allSatisfy { $0 == 0 })
        XCTAssertTrue(samples[0..<16_000].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(samples[40_000...].allSatisfy { $0 == 0.5 })
    }

    func testWordlessModelsNeverReceiveDictatedAudioButKeepTheRestOfTheirSegment() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"))
        var manifest = MeetingManifest(title: "Sync")
        _ = try store.createDirectory(for: manifest.id)
        try writeTrack(store.audioURL(for: manifest.id, track: .microphone), speechAt: [0.5, 0.9, 1.3, 1.7, 2.1])
        try writeTrack(store.audioURL(for: manifest.id, track: .system), speechAt: [1.2])
        manifest.updateTrack(.microphone) { $0.timeline.record(frame: 0, at: 0) }
        manifest.updateTrack(.system) { $0.timeline.record(frame: 0, at: 0) }
        manifest.dictationIntervals = [.init(start: 1.25, end: 1.75)]
        let fake = FakeTimedTranscriber()
        fake.isWordless = true

        let turns = try await MeetingTranscriber(
            transcriber: fake, model: try parakeet(), context: TranscriptionRequestContext(languages: ["en"])
        ).transcribe(manifest, store: store).turns

        // Them is transcribed first; You's 2 s of speech lose the dictated 0.5 s.
        XCTAssertEqual(fake.loudSeconds.count, 2)
        XCTAssertEqual(fake.loudSeconds[0], 0.4, accuracy: 0.05)
        XCTAssertEqual(fake.loudSeconds[1], 1.5, accuracy: 0.06)
        XCTAssertEqual(turns.map(\.speaker), [.you, .them])
    }

    func testTurnsInterleaveSpeakersAndMergeCloseEntries() {
        let entries = [
            MeetingTranscriptEntry(speaker: .them, start: 4, end: 6, text: "Hello."),
            MeetingTranscriptEntry(speaker: .you, start: 0, end: 2, text: "Hi."),
            MeetingTranscriptEntry(speaker: .you, start: 2.5, end: 3, text: " How are you? "),
            MeetingTranscriptEntry(speaker: .them, start: 8.5, end: 10, text: "Fine."),
            MeetingTranscriptEntry(speaker: .them, start: 20, end: 21, text: "Bye."),
            MeetingTranscriptEntry(speaker: .you, start: 30, end: 31, text: "  "),
        ]

        let turns = MeetingTranscript.turns(entries)

        XCTAssertEqual(turns.map(\.speaker), [.you, .them, .them])
        XCTAssertEqual(turns.map(\.text), ["Hi. How are you?", "Hello. Fine.", "Bye."])
        XCTAssertEqual(turns[1].end, 10)
    }

    // MARK: - Markdown

    func testMarkdownFollowsHexLayout() {
        var manifest = MeetingManifest(createdAt: Date(timeIntervalSince1970: 1_792_074_600), title: "Standup", provider: "zoom")
        manifest.duration = 3_725
        let turns = [
            MeetingTranscriptEntry(speaker: .you, start: 1, end: 2, text: "Hi."),
            MeetingTranscriptEntry(speaker: .them, start: 3_661, end: 3_662, text: "Hello."),
        ]

        // Foundation separates the time from AM/PM with a narrow no-break space.
        let markdown = MeetingMarkdown.render(
            manifest, turns: turns, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!
        ).replacingOccurrences(of: "\u{202F}", with: " ")

        XCTAssertEqual(markdown, """
            # Standup

            - **Date:** Thursday, October 15, 2026 at 2:30 PM
            - **Duration:** 1:02:05
            - **App:** Zoom

            ## Transcript

            **You** · 00:01
            Hi.

            **Them** · 1:01:01
            Hello.

            """)
        XCTAssertTrue(MeetingMarkdown.render(manifest, turns: []).contains("_No speech was transcribed._"))
    }

    func testFileNamesAreSafeAndShort() {
        let date = Date(timeIntervalSince1970: 1_792_074_600)
        let utc = TimeZone(identifier: "UTC")!
        let long = MeetingManifest(createdAt: date, title: "Q4: plan/budget? " + String(repeating: "x", count: 120))
        let hidden = MeetingManifest(createdAt: date, title: "..")

        XCTAssertEqual(MeetingMarkdown.fileName(for: long, timeZone: utc), "2026-10-15 1430 Q4- plan-budget- " + String(repeating: "x", count: 63) + ".md")
        XCTAssertEqual(MeetingMarkdown.fileName(for: hidden, timeZone: utc), "2026-10-15 1430 Meeting...md")
    }

    func testWritingNeverReplacesAnExistingTranscript() throws {
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)

        let first = try MeetingMarkdown.write("one", named: "a.md", in: folder)
        let second = try MeetingMarkdown.write("two", named: "a.md", in: folder)

        XCTAssertEqual(first.lastPathComponent, "a.md")
        XCTAssertEqual(second.lastPathComponent, "a (2).md")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), ["a (2).md", "a.md"])
    }

    // MARK: - Transcriber

    func testTracksAreTranscribedInMeetingTimeWithoutDictation() async throws {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"))
        var manifest = MeetingManifest(title: "Sync")
        _ = try store.createDirectory(for: manifest.id)
        try writeTrack(store.audioURL(for: manifest.id, track: .system), speechAt: [1.0])
        try writeTrack(store.audioURL(for: manifest.id, track: .microphone), speechAt: [0.5, 3.0])
        manifest.updateTrack(.system) { $0.timeline.record(frame: 0, at: 2) }
        manifest.updateTrack(.microphone) { $0.timeline.record(frame: 0, at: 0) }
        manifest.dictationIntervals = [.init(start: 2.8, end: 3.6)]
        let fake = FakeTimedTranscriber()
        var waits = 0

        let turns = try await MeetingTranscriber(
            transcriber: fake, model: try parakeet(), context: TranscriptionRequestContext(languages: ["en"]),
            waitForDictation: { waits += 1 }
        ).transcribe(manifest, store: store).turns

        XCTAssertEqual(turns.map(\.speaker), [.you, .them])
        XCTAssertEqual(turns[0].start, 0.5, accuracy: 0.25)
        XCTAssertEqual(turns[1].start, 3.0, accuracy: 0.25)
        XCTAssertEqual(turns.map(\.text), ["speech", "speech"])
        // The dictated burst at 3 s is silenced before voice detection, so no chunk is sent for it.
        XCTAssertEqual(waits, 2)
        XCTAssertEqual(fake.calls, 2)
    }

    func testModelChoiceKeepsACurrentLocalModelAndPrefersWordTimesOtherwise() throws {
        let parakeet = try parakeet()
        let unified = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-unified-0.6b" })
        let whisper = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "ggml-base" })
        let cloud = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.provider == .groq })

        XCTAssertEqual(MeetingTranscriptionModelChoice.choose(current: whisper, usable: [parakeet, whisper])?.name, "ggml-base")
        XCTAssertEqual(MeetingTranscriptionModelChoice.choose(current: cloud, usable: [cloud, unified, whisper, parakeet])?.name, parakeet.name)
        XCTAssertEqual(MeetingTranscriptionModelChoice.choose(current: cloud, usable: [cloud, unified])?.name, unified.name)
        XCTAssertNil(MeetingTranscriptionModelChoice.choose(current: cloud, usable: [cloud]))
    }

    // MARK: - Coordinator

    func testAStoppedMeetingIsTranscribedIntoTheChosenFolder() async throws {
        let fixture = try makeCoordinator()
        try await fixture.recorder.start(title: "Planning")
        let stopped = await fixture.recorder.stop()
        let recorded = try XCTUnwrap(stopped)
        try writeTrack(fixture.store.audioURL(for: recorded.id, track: .microphone), speechAt: [0.5])

        await fixture.coordinator.waitUntilIdle()

        let manifest = try fixture.store.load(id: recorded.id)
        XCTAssertEqual(manifest.status, .transcribed)
        let path = try XCTUnwrap(manifest.transcriptPath)
        XCTAssertTrue(path.hasPrefix(fixture.folder.path))
        let markdown = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix("# Planning\n"))
        XCTAssertTrue(markdown.contains("**\(String(localized: "You"))** · 00:00\nspeech"))
        await withCheckedContinuation { continuation in fixture.sleepQueue.async { continuation.resume() } }
        XCTAssertEqual(fixture.power.createdNames, [MeetingRecorder.assertionName, MeetingTranscriptionCoordinator.assertionName])
        XCTAssertEqual(fixture.transcriber.releaseCount, 1)
    }

    func testAFailedTranscriptionLeavesTheMeetingFailedAndRetryable() async throws {
        let fixture = try makeCoordinator()
        fixture.transcriber.failure = TimedTranscriptionError.unsupportedModel
        try await fixture.recorder.start()
        let stopped = await fixture.recorder.stop()
        let recorded = try XCTUnwrap(stopped)
        try writeTrack(fixture.store.audioURL(for: recorded.id, track: .microphone), speechAt: [0.5])
        await fixture.coordinator.waitUntilIdle()
        XCTAssertEqual(try fixture.store.load(id: recorded.id).status, .failed)

        fixture.transcriber.failure = nil
        fixture.coordinator.enqueue(recorded.id)
        await fixture.coordinator.waitUntilIdle()

        XCTAssertEqual(try fixture.store.load(id: recorded.id).status, .transcribed)
    }

    func testMeetingsAreTranscribedOneAtATimeWithBalancedHoldsAndReleases() async throws {
        let fixture = try makeCoordinator()
        fixture.transcriber.holdsCalls = true
        var ids: [UUID] = []
        for title in ["One", "Two"] {
            try await fixture.recorder.start(title: title)
            let stopped = await fixture.recorder.stop()
            let id = try XCTUnwrap(stopped?.id)
            try writeTrack(fixture.store.audioURL(for: id, track: .microphone), speechAt: [0.5])
            ids.append(id)
        }
        try await waitUntil { fixture.transcriber.heldCalls == 1 }
        fixture.coordinator.enqueue(ids[0])
        fixture.coordinator.enqueue(ids[1])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.transcriber.heldCalls, 1)
        XCTAssertEqual(fixture.coordinator.transcribingID, ids[0])

        fixture.transcriber.releaseHeldCalls()
        await fixture.coordinator.waitUntilIdle()

        XCTAssertEqual(fixture.transcriber.calls, 2)
        XCTAssertEqual(fixture.transcriber.maximumConcurrentCalls, 1)
        XCTAssertEqual(fixture.transcriber.releaseCount, 2)
        XCTAssertEqual(ids.map { try? fixture.store.load(id: $0).status }, [.transcribed, .transcribed])
        await withCheckedContinuation { continuation in fixture.sleepQueue.async { continuation.resume() } }
        XCTAssertTrue(fixture.power.liveAssertions.isEmpty)
    }

    func testAMeetingWhisperJobLoadsItsOwnContextOnceAndReleasesIt() async throws {
        let whisper = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "ggml-base" })
        let modelFile = root.appendingPathComponent("ggml-base.bin")
        FileManager.default.createFile(atPath: modelFile.path, contents: Data())
        var loads: [String] = []
        let context = FakeWhisperContext()
        let transcriber = MeetingWhisperTranscriber(
            modelURL: { $0 == "ggml-base" ? modelFile : nil },
            loadContext: { path in
                loads.append(path)
                return context
            }
        )
        let request = TranscriptionRequestContext(languages: ["en"])

        _ = try await transcriber.transcribeTimed(samples: [0.1], model: whisper, context: request)
        _ = try await transcriber.transcribeTimed(samples: [0.1], model: whisper, context: request)
        await transcriber.releaseResources()

        XCTAssertEqual(loads, [modelFile.path])
        XCTAssertEqual(context.calls, 2)
        XCTAssertEqual(context.releases, 1)
    }

    func testTheEchoCountIsSavedAndReplacedWhenTranscribedAgain() async throws {
        let fixture = try makeCoordinator()
        fixture.transcriber.text = "Ship the beta on Friday"
        try await fixture.recorder.start()
        let stopped = await fixture.recorder.stop()
        let id = try XCTUnwrap(stopped?.id)
        // The microphone carries the remote audio and words at the same moment, as speaker bleed would; 2 s of
        // remote speech give the coupling estimate enough frames.
        let bursts = [0.5, 0.9, 1.3, 1.7, 2.1]
        try writeTrack(fixture.store.audioURL(for: id, track: .system), speechAt: bursts)
        try writeTrack(fixture.store.audioURL(for: id, track: .microphone), speechAt: bursts)
        await fixture.coordinator.waitUntilIdle()
        XCTAssertEqual(try fixture.store.load(id: id).echoSuppressedUtterances, 1)

        fixture.transcriber.microphoneSilent = true
        fixture.coordinator.enqueue(id)
        await fixture.coordinator.waitUntilIdle()

        XCTAssertEqual(try fixture.store.load(id: id).echoSuppressedUtterances, 0)
    }

    func testRecordingRequiresALocalModel() async throws {
        let fixture = try makeCoordinator(hasModel: false)

        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start(), MeetingRecorderError.noLocalModel)
    }

    func testChunksWaitWhileADictationRuns() async throws {
        let fixture = try makeCoordinator()
        fixture.dictation.isActive = true
        try await fixture.recorder.start()
        let stopped = await fixture.recorder.stop()
        let recorded = try XCTUnwrap(stopped)
        try writeTrack(fixture.store.audioURL(for: recorded.id, track: .microphone), speechAt: [0.5])

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(fixture.transcriber.calls, 0)
        fixture.dictation.isActive = false
        await fixture.coordinator.waitUntilIdle()

        XCTAssertEqual(fixture.transcriber.calls, 1)
    }

    // MARK: - Fixtures

    private func parakeet() throws -> any TranscriptionModel {
        try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
    }

    /// A 5 s, 16 kHz PCM16 track with 0.4 s tone bursts at the given seconds.
    private func writeTrack(_ url: URL, speechAt starts: [Double]) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000)!
        buffer.frameLength = 80_000
        let samples = buffer.int16ChannelData![0]
        for index in 0..<80_000 {
            let time = Double(index) / 16_000
            let speaking = starts.contains { time >= $0 && time < $0 + 0.4 }
            samples[index] = speaking ? Int16(8_000 * sin(Double(index) * 0.2)) : 0
        }
        try file.write(from: buffer)
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private struct CoordinatorFixture {
        let coordinator: MeetingTranscriptionCoordinator
        let recorder: MeetingRecorder
        let store: MeetingStore
        let transcriber: FakeTimedTranscriber
        let power: TranscriptPowerAssertions
        let sleepQueue: DispatchQueue
        let dictation: DictationState
        let folder: URL
    }

    private func makeCoordinator(hasModel: Bool = true) throws -> CoordinatorFixture {
        let store = MeetingStore(rootURL: root.appendingPathComponent("store"))
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)
        let transcriber = FakeTimedTranscriber()
        let power = TranscriptPowerAssertions()
        let sleepQueue = DispatchQueue(label: "MeetingTranscriptTests.sleep")
        let sleep = IdleSleepPrevention(client: power, queue: sleepQueue)
        let dictation = DictationState()
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let model = try parakeet()
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = store
        dependencies.permission = GrantedSystemAudio()
        dependencies.makeSystemAudio = { SilentSystemAudio() }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { FakeMeetingMicrophoneHardware() }) }
        dependencies.isMicrophoneAuthorized = { true }
        dependencies.idleSleep = sleep
        dependencies.defaults = defaults
        let recorder = MeetingRecorder(dependencies: dependencies)
        let coordinator = MeetingTranscriptionCoordinator()
        coordinator.configure(
            environment: .init(
                chooseModel: { hasModel ? model : nil }, makeTranscriber: { _ in transcriber },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) },
                isDictating: { dictation.isActive }, outputFolder: { folder }, idleSleep: sleep,
                dictationPollInterval: .milliseconds(10)
            ),
            recorder: recorder
        )
        return CoordinatorFixture(
            coordinator: coordinator, recorder: recorder, store: store, transcriber: transcriber, power: power,
            sleepQueue: sleepQueue, dictation: dictation, folder: folder
        )
    }
}

@MainActor
private final class DictationState {
    var isActive = false
}

/// Reports one "speech" segment per chunk at the chunk's loudest sample.
@MainActor
private final class FakeTimedTranscriber: TimedSpeechTranscribing {
    var calls = 0
    var releaseCount = 0
    var failure: Error?
    /// Reports one segment without words, like Unified, Nemotron or Whisper.
    var isWordless = false
    /// Seconds of non-silent audio received per track, in call order.
    var loudSeconds: [Double] = []
    var holdsCalls = false
    var text = "speech"
    /// Reports nothing for the second track of each meeting (the microphone).
    var microphoneSilent = false
    private(set) var heldCalls = 0
    private(set) var maximumConcurrentCalls = 0
    private var activeCalls = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    func releaseHeldCalls() {
        holdsCalls = false
        held.forEach { $0.resume() }
        held = []
    }

    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        calls += 1
        activeCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
        defer { activeCalls -= 1 }
        if holdsCalls {
            heldCalls += 1
            await withCheckedContinuation { held.append($0) }
        }
        if let failure { throw failure }
        loudSeconds.append(Double(samples.filter { abs($0) > 0.01 }.count) / 16_000)
        if microphoneSilent, calls % 2 == 0 { return [] }
        if isWordless {
            return TimedTranscriptSegment.untimed(text, sampleCount: samples.count)
        }
        guard let loud = samples.firstIndex(where: { abs($0) > 0.1 }) else { return [] }
        let start = Double(loud) / 16_000
        return [TimedTranscriptSegment(
            text: text, start: start, end: start + 0.4, words: [TimedTranscriptWord(text: text, start: start, end: start + 0.4)]
        )]
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }

    func releaseResources() async { releaseCount += 1 }
}

private final class GrantedSystemAudio: SystemAudioAuthorizing {
    func status() -> SystemAudioAuthorization { .granted }
    func request() async -> SystemAudioAuthorization { .granted }
}

private final class SilentSystemAudio: SystemAudioCapturing, @unchecked Sendable {
    var lastDeliveryNanoseconds: UInt64? { DispatchTime.now().uptimeNanoseconds }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {}
    func restart() throws {}
    func stop() -> MeetingTrackCaptureResult { MeetingTrackCaptureResult() }
}

private final class TranscriptPowerAssertions: PowerAssertionClient, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (names: [String](), live: Set<IOPMAssertionID>(), next: IOPMAssertionID(1)))
    var createdNames: [String] { state.withLock { $0.names } }
    var liveAssertions: Set<IOPMAssertionID> { state.withLock { $0.live } }

    func createIdleSleepAssertion(named name: String) -> Result<IOPMAssertionID, IdleSleepPreventionError> {
        state.withLock {
            $0.names.append(name)
            $0.next += 1
            $0.live.insert($0.next)
            return .success($0.next)
        }
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        state.withLock { $0.live.remove(id) != nil ? kIOReturnSuccess : kIOReturnNotFound }
    }
}

private final class FakeWhisperContext: TimedWhisperContext {
    var calls = 0
    var releases = 0

    func transcribeTimed(samples: [Float], request: TranscriptionRequestContext) async throws -> [TimedTranscriptSegment] {
        calls += 1
        return []
    }

    func releaseResources() async { releases += 1 }
}
