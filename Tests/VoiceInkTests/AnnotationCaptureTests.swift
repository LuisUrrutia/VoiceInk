import AVFoundation
import IOKit.pwr_mgt
import XCTest
import os

@testable import VoiceInk

@MainActor final class AnnotationCaptureTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AnnotationCaptureTests-\(UUID().uuidString)")
        suiteName = "AnnotationCaptureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .annotate, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Recorder

    func testStartRequiresTheSwitchMicrophoneScreenAndNoMeeting() async {
        Labs.setEnabled(false, for: .annotate, in: defaults)
        await XCTAssertThrowsErrorAsync(try await makeFixture().recorder.start(), AnnotationRecorderError.featureDisabled)

        Labs.setEnabled(true, for: .annotate, in: defaults)
        await XCTAssertThrowsErrorAsync(try await makeFixture(meeting: true).recorder.start(), AnnotationRecorderError.meetingRecording)
        await XCTAssertThrowsErrorAsync(try await makeFixture(microphone: false).recorder.start(), AnnotationRecorderError.microphoneNotAuthorized)
        let denied = makeFixture(screen: false)
        await XCTAssertThrowsErrorAsync(try await denied.recorder.start(), AnnotationRecorderError.screenNotAuthorized)
        XCTAssertEqual(denied.screen.startCount, 0)
        XCTAssertTrue(denied.store.loadAll().isEmpty)
    }

    func testAnAnnotationRecordsTheDisplayAndNarrationOnOneTimeline() async throws {
        let fixture = makeFixture()
        var recorded: [UUID] = []
        fixture.recorder.onRecorded = { recorded.append($0.id) }

        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        fixture.clock.advance(seconds: 0.2)
        fixture.screen.firstFrame = fixture.clock.now
        fixture.clock.advance(seconds: 1)
        fixture.microphone.emit(frames: 16_000, capturedThrough: fixture.clock.now)
        fixture.clock.advance(seconds: 2)
        let stopped = await fixture.recorder.stop()

        let manifest = try XCTUnwrap(stopped)
        XCTAssertEqual(manifest.status, .processing)
        XCTAssertEqual(manifest.duration, 3.2, accuracy: 0.001)
        XCTAssertEqual(manifest.videoOffset ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(manifest.display?.id, 7)
        XCTAssertEqual(manifest.narrationTimeline.time(forFrame: 0), 0.2, accuracy: 0.001)
        XCTAssertEqual(fixture.screen.url, fixture.store.url(for: id, file: AnnotationManifest.videoFileName))
        XCTAssertEqual(fixture.microphone.startedURL, fixture.store.url(for: id, file: AnnotationManifest.narrationFileName))
        XCTAssertEqual(try fixture.store.load(id: id), manifest)
        XCTAssertEqual(recorded, [id])
        await withCheckedContinuation { continuation in fixture.sleepQueue.async { continuation.resume() } }
        XCTAssertEqual(fixture.power.names, [AnnotationRecorder.assertionName])
        XCTAssertTrue(fixture.power.live.isEmpty)
    }

    func testCancelDiscardsTheAnnotation() async throws {
        let fixture = makeFixture()
        var recorded = 0
        fixture.recorder.onRecorded = { _ in recorded += 1 }
        try await fixture.recorder.start()

        await fixture.recorder.cancel()

        XCTAssertTrue(fixture.store.loadAll().isEmpty)
        XCTAssertEqual(fixture.screen.stopCount, 1)
        XCTAssertEqual(fixture.microphone.stopCount, 1)
        XCTAssertEqual(recorded, 0)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testAnAnnotationStopsAtItsMaximumDuration() async throws {
        let fixture = makeFixture(maximumDuration: .milliseconds(30))
        try await fixture.recorder.start()

        try await waitUntil { !fixture.recorder.isRecording }

        XCTAssertEqual(fixture.store.loadAll().first?.status, .processing)
    }

    func testTurningAnnotateOffDiscardsARecording() async throws {
        let fixture = makeFixture()
        try await fixture.recorder.start()

        Labs.setEnabled(false, for: .annotate, in: defaults)

        try await waitUntil { !fixture.recorder.isRecording && fixture.store.loadAll().isEmpty }
    }

    func testAScreenFailureAtStartLeavesNothingBehind() async throws {
        let fixture = makeFixture()
        fixture.screen.startFailure = ScreenRecordingError.displayUnavailable

        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start(), ScreenRecordingError.displayUnavailable)

        XCTAssertTrue(fixture.store.loadAll().isEmpty)
        XCTAssertEqual(fixture.microphone.startCount, 0)
    }

    func testTheAnnotateShortcutIsMonitoredOnlyWhileAnnotateIsOn() {
        XCTAssertTrue(ShortcutAction.activeGlobalUtilityActions(defaults: defaults).contains(.toggleAnnotate))
        Labs.setEnabled(false, for: .annotate, in: defaults)
        XCTAssertFalse(ShortcutAction.activeGlobalUtilityActions(defaults: defaults).contains(.toggleAnnotate))
        XCTAssertTrue(ShortcutAction.storedGlobalActions.contains(.toggleAnnotate))
    }

    func testRecordingSizesKeepTheAspectRatioWithinTheLongEdge() {
        XCTAssertTrue(ScreenCaptureKitRecording.outputSize(points: CGSize(width: 1_512, height: 982), scale: 2) == (2_560, 1_662))
        XCTAssertTrue(ScreenCaptureKitRecording.outputSize(points: CGSize(width: 1_920, height: 1_080), scale: 1) == (1_920, 1_080))
        XCTAssertTrue(ScreenCaptureKitRecording.outputSize(points: CGSize(width: 1_081, height: 1_921), scale: 1) == (1_080, 1_920))
    }

    // MARK: - Processing

    func testProcessingTranscribesTheNarrationAndCopiesTheSummary() async throws {
        let fixture = makeFixture()
        let processor = AnnotationProcessor()
        var copied: [String] = []
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        processor.configure(
            environment: .init(
                chooseModel: { model }, makeTranscriber: { _ in NarrationTranscriber() },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { copied.append($0) },
                notify: { _ in }
            ),
            recorder: fixture.recorder
        )
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        fixture.microphone.emit(frames: 1_600, capturedThrough: fixture.clock.now + 100_000_000)
        fixture.clock.advance(seconds: 5)
        _ = await fixture.recorder.stop()
        try writeNarration(to: fixture.store.url(for: id, file: AnnotationManifest.narrationFileName), toneAt: 1)

        await processor.waitUntilIdle()

        let manifest = try fixture.store.load(id: id)
        XCTAssertEqual(manifest.status, .ready)
        XCTAssertEqual(manifest.transcript.map(\.text), ["this button is broken"])
        XCTAssertEqual(manifest.transcriptModel, model.name)
        let summary = try String(contentsOf: fixture.store.url(for: id, file: AnnotationManifest.summaryFileName), encoding: .utf8)
        XCTAssertEqual(copied, [summary])
        XCTAssertTrue(summary.contains(fixture.store.directory(for: id).path))
        XCTAssertTrue(summary.contains("“this button is broken”"))
    }

    func testTheSummaryNamesTheBundleAndSaysWhenNothingWasSaid() {
        var manifest = AnnotationManifest(createdAt: Date(timeIntervalSince1970: 1_792_074_600))
        manifest.duration = 42
        let folder = URL(fileURLWithPath: "/tmp/Annotations/X")

        let summary = AnnotationSummary.render(manifest, folder: folder, locale: Locale(identifier: "en_US"))

        XCTAssertTrue(summary.hasPrefix("# \(String(localized: "Annotation")) · "))
        XCTAssertTrue(summary.contains("00:42"))
        XCTAssertTrue(summary.contains("/tmp/Annotations/X"))
        XCTAssertTrue(summary.contains("`recording.mp4`"))
        XCTAssertTrue(summary.contains("_\(String(localized: "No narration was transcribed."))_"))
    }

    // MARK: - Fixture

    private struct Fixture {
        let recorder: AnnotationRecorder
        let store: AnnotationStore
        let screen: FakeScreenRecording
        let microphone: FakeMeetingMicrophoneHardware
        let power: AnnotationPowerAssertions
        let sleepQueue: DispatchQueue
        let clock: AnnotationClock
    }

    private func makeFixture(
        meeting: Bool = false, microphone isMicrophoneAuthorized: Bool = true, screen isScreenAuthorized: Bool = true,
        maximumDuration: Duration = .seconds(1_200)
    ) -> Fixture {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        let screen = FakeScreenRecording()
        let hardware = FakeMeetingMicrophoneHardware()
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let power = AnnotationPowerAssertions()
        let sleepQueue = DispatchQueue(label: "AnnotationCaptureTests.sleep")
        let clock = AnnotationClock()
        var dependencies = AnnotationRecorder.Dependencies()
        dependencies.store = store
        dependencies.makeScreen = { screen }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { hardware }) }
        dependencies.isScreenAuthorized = { isScreenAuthorized }
        dependencies.requestScreenAccess = { false }
        dependencies.isMicrophoneAuthorized = { isMicrophoneAuthorized }
        dependencies.isMeetingRecording = { meeting }
        dependencies.displayUnderPointer = { 7 }
        dependencies.idleSleep = IdleSleepPrevention(client: power, queue: sleepQueue)
        dependencies.now = { clock.now }
        dependencies.defaults = defaults
        dependencies.maximumDuration = maximumDuration
        return Fixture(
            recorder: AnnotationRecorder(dependencies: dependencies), store: store, screen: screen, microphone: hardware,
            power: power, sleepQueue: sleepQueue, clock: clock
        )
    }

    private func writeNarration(to url: URL, toneAt second: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 {
            let time = Double(index) / 16_000
            buffer.int16ChannelData![0][index] = time >= second && time < second + 0.5 ? Int16(8_000 * sin(Double(index) * 0.2)) : 0
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
}

private final class AnnotationClock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<UInt64>(initialState: 5_000_000_000_000)
    var now: UInt64 { value.withLock { $0 } }
    func advance(seconds: Double) { value.withLock { $0 += UInt64(seconds * 1_000_000_000) } }
}

private final class FakeScreenRecording: ScreenRecording {
    var url: URL?
    var startCount = 0
    var stopCount = 0
    var firstFrame: UInt64?
    var startFailure: Error?

    func start(displayID: CGDirectDisplayID, writingTo url: URL) async throws -> AnnotationManifest.Display {
        if let startFailure { throw startFailure }
        self.url = url
        startCount += 1
        return AnnotationManifest.Display(id: displayID, width: 2_560, height: 1_662, scale: 2)
    }

    func stop() async throws -> ScreenRecordingResult {
        stopCount += 1
        return ScreenRecordingResult(
            display: AnnotationManifest.Display(id: 7, width: 2_560, height: 1_662, scale: 2), firstFrameNanoseconds: firstFrame
        )
    }
}

/// Hears one sentence where the narration is loud.
private final class NarrationTranscriber: TimedSpeechTranscribing {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        guard samples.contains(where: { abs($0) > 0.1 }) else { return [] }
        return [TimedTranscriptSegment(text: "this button is broken", start: 0.2, end: 1.0)]
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}

private final class AnnotationPowerAssertions: PowerAssertionClient, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (names: [String](), live: Set<IOPMAssertionID>(), next: IOPMAssertionID(1)))
    var names: [String] { state.withLock { $0.names } }
    var live: Set<IOPMAssertionID> { state.withLock { $0.live } }

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
