import AVFoundation
import IOKit.pwr_mgt
import SwiftData
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

    func testInkAndClicksAreSavedWithMarksAndThePenFollowsTheCapsule() async throws {
        let fixture = makeFixture()
        try await fixture.recorder.start()
        XCTAssertEqual(fixture.input.startedDisplay, 7)
        fixture.recorder.setPenEnabled(true)
        XCTAssertTrue(fixture.input.isPenEnabled)
        XCTAssertTrue(fixture.recorder.isPenEnabled)
        fixture.input.strokes = [AnnotationStroke(points: [.init(x: 0.2, y: 0.6, t: 1), .init(x: 0.8, y: 0.6, t: 1.4)])]
        fixture.input.events = [AnnotationEvent(kind: .click, t: 2, x: 0.4, y: 0.4)]

        let stopped = await fixture.recorder.stop()

        let manifest = try XCTUnwrap(stopped)
        XCTAssertEqual(manifest.strokes.count, 1)
        XCTAssertEqual(manifest.events, fixture.input.events)
        XCTAssertEqual(manifest.marks.map(\.shape), [.underline])
        XCTAssertEqual(fixture.input.stopCount, 1)
        XCTAssertFalse(fixture.recorder.isPenEnabled)
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
        XCTAssertEqual(fixture.input.stopCount, 1)
        XCTAssertEqual(recorded, 0)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testAnAnnotationStopsAtItsMaximumDuration() async throws {
        let fixture = makeFixture(maximumDuration: .milliseconds(30))
        try await fixture.recorder.start()

        try await waitUntil { !fixture.recorder.isRecording }

        XCTAssertEqual(fixture.store.loadAll().first?.status, .processing)
    }

    func testTheDurationLimitDoesNotCancelTheMoviesFinish() async throws {
        let fixture = makeFixture(maximumDuration: .milliseconds(20))
        fixture.screen.finishDelay = .milliseconds(80)
        var recorded = 0
        fixture.recorder.onRecorded = { _ in recorded += 1 }
        try await fixture.recorder.start()

        try await waitUntil { !fixture.recorder.isBusy }

        XCTAssertEqual(fixture.store.loadAll().first?.status, .processing)
        XCTAssertNil(fixture.store.loadAll().first?.failure)
        XCTAssertEqual(recorded, 1)
    }

    func testAStopThatNeverFinishesIsAbandonedAtTheTimeout() async {
        let started = ContinuousClock.now

        let outcome = await ScreenCaptureKitRecording.firstOutcome(timeout: .milliseconds(50)) {
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }

        XCTAssertThrowsError(try outcome.get()) { XCTAssertEqual($0 as? ScreenRecordingError, .finishTimedOut) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    func testMeetingsAndAnnotationsExcludeEachOtherInBothOrdersAndWhileStarting() async throws {
        let fixture = makeFixture()
        let meeting = makeMeetingRecorder(annotations: fixture.recorder)
        fixture.screen.holdsStart = true
        let start = Task { try await fixture.recorder.start() }
        try await waitUntil { fixture.screen.isHoldingStart }

        await XCTAssertThrowsErrorAsync(try await meeting.start(), MeetingRecorderError.annotationRecording)
        fixture.screen.release()
        try await start.value
        await XCTAssertThrowsErrorAsync(try await meeting.start(), MeetingRecorderError.annotationRecording)
        await fixture.recorder.stop()

        try await meeting.start()
        let blocked = makeFixture(meeting: meeting.isBusy)
        await XCTAssertThrowsErrorAsync(try await blocked.recorder.start(), AnnotationRecorderError.meetingRecording)
        _ = await meeting.stop()
    }

    func testTheReservationLastsUntilTeardownFinishes() async throws {
        let fixture = makeFixture()
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        fixture.screen.holdsStop = true
        let stop = Task { await fixture.recorder.stop() }
        try await waitUntil { fixture.screen.isHoldingStop }

        XCTAssertTrue(fixture.recorder.isBusy)
        XCTAssertEqual(fixture.recorder.ownedAnnotationID, id)
        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start(), AnnotationRecorderError.alreadyRecording)
        fixture.recorder.delete(try fixture.store.load(id: id))
        XCTAssertNotNil(try? fixture.store.load(id: id))

        fixture.screen.release()
        _ = await stop.value
        XCTAssertFalse(fixture.recorder.isBusy)
        XCTAssertNil(fixture.recorder.ownedAnnotationID)
    }

    func testCancelOrSwitchingOffDuringStopDiscardsTheAnnotation() async throws {
        for switchesOff in [false, true] {
            let fixture = makeFixture()
            var recorded = 0
            fixture.recorder.onRecorded = { _ in recorded += 1 }
            try await fixture.recorder.start()
            fixture.screen.holdsStop = true
            let stop = Task { await fixture.recorder.stop() }
            try await waitUntil { fixture.screen.isHoldingStop }

            if switchesOff {
                Labs.setEnabled(false, for: .annotate, in: defaults)
                try await Task.sleep(for: .milliseconds(20))
            } else {
                await fixture.recorder.cancel()
            }
            fixture.screen.release()
            let result = await stop.value

            XCTAssertNil(result)
            XCTAssertEqual(recorded, 0)
            XCTAssertTrue(fixture.store.loadAll().isEmpty)
            XCTAssertFalse(fixture.recorder.isBusy)
            Labs.setEnabled(true, for: .annotate, in: defaults)
        }
    }

    func testDictationIsRefusedWhileAnnotatingAndItsActionStopsTheAnnotation() async throws {
        let fixture = makeFixture()
        try await fixture.recorder.start()
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let hardware = FakeMeetingMicrophoneHardware()
        let whisper = WhisperModelManager(modelsDirectory: root.appendingPathComponent("models"))
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let container = try ModelContainer(for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper, transcriptionModelManager: models,
            recorder: Recorder(hardware: hardware, deviceManager: devices),
            captureReadiness: CaptureReadinessController(models: models, devices: devices, permissionReader: { (.granted, false) }),
            annotations: fixture.recorder
        )

        await engine.toggleRecord()

        XCTAssertEqual(hardware.startCount, 0)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertEqual(engine.recordingError, String(localized: "Finish the annotation before dictating."))
        engine.preflightFailureAction?()
        try await waitUntil { !fixture.recorder.isBusy }
        XCTAssertEqual(fixture.store.loadAll().first?.status, .processing)
    }

    func testAMeetingHeldInItsStartOrStopKeepsAnnotateOut() async throws {
        let annotation = makeFixture()
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let microphone = FakeMeetingMicrophoneHardware()
        Labs.setEnabled(true, for: .meetings, in: defaults)
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = MeetingStore(rootURL: root.appendingPathComponent("meetings"))
        dependencies.permission = AnnotationTestSystemAudio()
        dependencies.makeSystemAudio = { AnnotationTestTap() }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { microphone }) }
        dependencies.isMicrophoneAuthorized = { true }
        dependencies.isOtherCaptureBusy = { annotation.recorder.isBusy }
        dependencies.defaults = defaults
        let meeting = MeetingRecorder(dependencies: dependencies)
        let blocked = makeFixture(meetingBusy: { meeting.isBusy })

        microphone.holdStart = true
        let start = Task { try await meeting.start() }
        try await waitUntil { meeting.isStarting }
        await XCTAssertThrowsErrorAsync(try await blocked.recorder.start(), AnnotationRecorderError.meetingRecording)
        microphone.releaseStart()
        try await start.value

        microphone.holdStop = true
        let stop = Task { await meeting.stop() }
        try await waitUntil { meeting.isStopping }
        await XCTAssertThrowsErrorAsync(try await blocked.recorder.start(), AnnotationRecorderError.meetingRecording)
        microphone.releaseStop()
        _ = await stop.value
        try await blocked.recorder.start()
        await blocked.recorder.cancel()
    }

    func testProcessingSavesNarrationWordsInAnnotationTimeAcrossAGap() async throws {
        let fixture = makeFixture()
        let processor = AnnotationProcessor()
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        processor.configure(
            environment: .init(
                chooseModel: { model }, makeTranscriber: { _ in WordTranscriber() },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { _ in }, notify: { _ in }
            ),
            recorder: fixture.recorder
        )
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        let start = fixture.clock.now
        // 0.1 s captured at 1.0 s, then a capture gap until 5.0 s.
        fixture.microphone.emit(frames: 1_600, capturedThrough: start + 1_100_000_000)
        fixture.microphone.emit(frames: 1_600, capturedThrough: start + 5_100_000_000)
        fixture.clock.advance(seconds: 8)
        _ = await fixture.recorder.stop()
        try writeNarration(to: fixture.store.url(for: id, file: AnnotationManifest.narrationFileName), toneAt: 1)

        await processor.waitUntilIdle()

        let word = try XCTUnwrap(try fixture.store.load(id: id).transcript.first?.words.first)
        XCTAssertEqual(word.start, 5.9, accuracy: 0.05)
    }

    func testANarrationCaptureFailureIsKeptAndShownInTheHandoff() async throws {
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
        fixture.microphone.failureAfterStop = RecordingAudioError.conversionFailed
        _ = await fixture.recorder.stop()
        // The partial narration is still readable.
        try writeNarration(to: fixture.store.url(for: id, file: AnnotationManifest.narrationFileName), toneAt: 1)

        await processor.waitUntilIdle()

        let manifest = try fixture.store.load(id: id)
        XCTAssertEqual(manifest.status, .ready)
        XCTAssertEqual(manifest.narrationFailure, RecordingAudioError.conversionFailed.localizedDescription)
        XCTAssertEqual(manifest.transcript.map(\.text), ["this button is broken"])
        XCTAssertEqual(copied.count, 1)
        XCTAssertTrue(copied[0].contains(RecordingAudioError.conversionFailed.localizedDescription))
    }

    func testAFailedBundleWriteMarksTheAnnotationFailedWithoutAHandoff() async throws {
        let fixture = makeFixture()
        let processor = AnnotationProcessor()
        var copied = 0
        var notified = 0
        processor.configure(
            environment: .init(
                chooseModel: { nil }, makeTranscriber: { _ in WordTranscriber() },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { _ in copied += 1 },
                notify: { _ in notified += 1 }
            ),
            recorder: fixture.recorder
        )
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        _ = await fixture.recorder.stop()
        // A directory where the summary goes makes its write fail.
        try FileManager.default.createDirectory(
            at: fixture.store.url(for: id, file: AnnotationManifest.summaryFileName), withIntermediateDirectories: false
        )

        await processor.waitUntilIdle()

        XCTAssertEqual(try fixture.store.load(id: id).status, .failed)
        XCTAssertEqual(copied, 0)
        XCTAssertEqual(notified, 0)
    }

    func testStopAnnotationAbandonsAPendingStart() async throws {
        let fixture = makeFixture()
        fixture.screen.holdsStart = true
        let start = Task { try await fixture.recorder.start() }
        try await waitUntil { fixture.screen.isHoldingStart }

        await fixture.recorder.stopOrCancelStart()
        fixture.screen.release()

        await XCTAssertThrowsErrorAsync(try await start.value, AnnotationRecorderError.cancelled)
        XCTAssertFalse(fixture.recorder.isBusy)
        XCTAssertTrue(fixture.store.loadAll().isEmpty)
        XCTAssertEqual(fixture.screen.stopCount, 1)
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

    func testProcessingWithoutAModelOrWithAFailureStillHandsOffASummary() async throws {
        for failing in [false, true] {
            let fixture = makeFixture()
            let processor = AnnotationProcessor()
            var copied: [String] = []
            let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
            processor.configure(
                environment: .init(
                    chooseModel: { failing ? model : nil }, makeTranscriber: { _ in FailingTranscriber() },
                    requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { copied.append($0) },
                    notify: { _ in }
                ),
                recorder: fixture.recorder
            )
            try await fixture.recorder.start()
            let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
            _ = await fixture.recorder.stop()
            try writeNarration(to: fixture.store.url(for: id, file: AnnotationManifest.narrationFileName), toneAt: 1)

            await processor.waitUntilIdle()

            let manifest = try fixture.store.load(id: id)
            XCTAssertEqual(manifest.status, .ready)
            let failure = try XCTUnwrap(manifest.failure)
            XCTAssertEqual(copied.count, 1)
            XCTAssertTrue(copied[0].contains(failure))
            XCTAssertTrue(copied[0].contains("_\(String(localized: "No narration was transcribed."))_"))
        }
    }

    func testNarrationWordsMapAcrossGappedAnchors() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0.5)
        timeline.record(frame: 16_000, at: 4)
        let segment = TimedTranscriptSegment(
            text: "here it breaks", start: 0.5, end: 1.5,
            words: [TimedTranscriptWord(text: "here", start: 0.5, end: 0.8), TimedTranscriptWord(text: "breaks", start: 1.2, end: 1.5)]
        )

        let mapped = MeetingTranscriber.meetingTime(segment, timeline: timeline)

        XCTAssertEqual(mapped.start, 1.0, accuracy: 0.001)
        XCTAssertEqual(mapped.words[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(mapped.words[1].start, 4.2, accuracy: 0.001)
    }

    func testDeletingIsRefusedWhileProcessingWritesTheBundle() async throws {
        let fixture = makeFixture()
        let processor = AnnotationProcessor()
        let transcriber = HeldTranscriber()
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        var copied = 0
        processor.configure(
            environment: .init(
                chooseModel: { model }, makeTranscriber: { _ in transcriber },
                requestContext: { _ in TranscriptionRequestContext(languages: ["en"]) }, copy: { _ in copied += 1 },
                notify: { _ in }
            ),
            recorder: fixture.recorder
        )
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeAnnotation?.id)
        _ = await fixture.recorder.stop()
        try writeNarration(to: fixture.store.url(for: id, file: AnnotationManifest.narrationFileName), toneAt: 1)
        try await waitUntil { transcriber.isHeld }

        fixture.recorder.delete(try fixture.store.load(id: id))
        XCTAssertNotNil(try? fixture.store.load(id: id))
        // A bundle removed outside VoiceInk meanwhile gets no late handoff.
        try FileManager.default.removeItem(at: fixture.store.directory(for: id))
        transcriber.release()
        await processor.waitUntilIdle()

        XCTAssertEqual(copied, 0)
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

    private func makeMeetingRecorder(annotations: AnnotationRecorder) -> MeetingRecorder {
        let devices = MeetingAudioDevices(userDefaults: defaults)
        Labs.setEnabled(true, for: .meetings, in: defaults)
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = MeetingStore(rootURL: root.appendingPathComponent("meetings"))
        dependencies.permission = AnnotationTestSystemAudio()
        dependencies.makeSystemAudio = { AnnotationTestTap() }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { FakeMeetingMicrophoneHardware() }) }
        dependencies.isMicrophoneAuthorized = { true }
        dependencies.isOtherCaptureBusy = { annotations.isBusy }
        dependencies.defaults = defaults
        return MeetingRecorder(dependencies: dependencies)
    }

    private struct Fixture {
        let recorder: AnnotationRecorder
        let store: AnnotationStore
        let screen: FakeScreenRecording
        let input: FakeAnnotationInput
        let microphone: FakeMeetingMicrophoneHardware
        let power: AnnotationPowerAssertions
        let sleepQueue: DispatchQueue
        let clock: AnnotationClock
    }

    private func makeFixture(
        meeting: Bool = false, meetingBusy: (@MainActor () -> Bool)? = nil, microphone isMicrophoneAuthorized: Bool = true,
        screen isScreenAuthorized: Bool = true, maximumDuration: Duration = .seconds(1_200)
    ) -> Fixture {
        let store = AnnotationStore(rootURL: root, movesToTrash: false)
        let screen = FakeScreenRecording()
        let input = FakeAnnotationInput()
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
        dependencies.isMeetingRecording = meetingBusy ?? { meeting }
        dependencies.displayUnderPointer = { 7 }
        dependencies.makeInput = { input }
        dependencies.idleSleep = IdleSleepPrevention(client: power, queue: sleepQueue)
        dependencies.now = { clock.now }
        dependencies.defaults = defaults
        dependencies.maximumDuration = maximumDuration
        return Fixture(
            recorder: AnnotationRecorder(dependencies: dependencies), store: store, screen: screen, input: input, microphone: hardware,
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

@MainActor
private final class FakeScreenRecording: ScreenRecording {
    var url: URL?
    var startCount = 0
    var stopCount = 0
    var firstFrame: UInt64?
    var startFailure: Error?
    /// Suspends start or stop until released, as slow ScreenCaptureKit calls would.
    var holdsStart = false
    var holdsStop = false
    /// A cancellation-aware movie finish, like the real stop's wait.
    var finishDelay: Duration?
    private(set) var isHoldingStart = false
    private(set) var isHoldingStop = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func release() {
        holdsStart = false
        holdsStop = false
        held.forEach { $0.resume() }
        held = []
    }

    func start(displayID: CGDirectDisplayID, writingTo url: URL) async throws -> AnnotationManifest.Display {
        if holdsStart {
            isHoldingStart = true
            await withCheckedContinuation { held.append($0) }
            isHoldingStart = false
        }
        if let startFailure { throw startFailure }
        self.url = url
        startCount += 1
        return AnnotationManifest.Display(id: displayID, width: 2_560, height: 1_662, scale: 2)
    }

    func stop() async throws -> ScreenRecordingResult {
        stopCount += 1
        if holdsStop {
            isHoldingStop = true
            await withCheckedContinuation { held.append($0) }
            isHoldingStop = false
        }
        if let finishDelay { try await Task.sleep(for: finishDelay) }
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

private final class FailingTranscriber: TimedSpeechTranscribing {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        throw TimedTranscriptionError.unsupportedModel
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}

@MainActor
private final class HeldTranscriber: TimedSpeechTranscribing {
    private(set) var isHeld = false
    private var continuation: CheckedContinuation<Void, Never>?

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        isHeld = true
        await withCheckedContinuation { continuation = $0 }
        return []
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}

private final class AnnotationTestSystemAudio: SystemAudioAuthorizing {
    func status() -> SystemAudioAuthorization { .granted }
    func request() async -> SystemAudioAuthorization { .granted }
}

private final class AnnotationTestTap: SystemAudioCapturing, @unchecked Sendable {
    var lastDeliveryNanoseconds: UInt64? { DispatchTime.now().uptimeNanoseconds }
    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {}
    func restart() throws {}
    func stop() -> MeetingTrackCaptureResult { MeetingTrackCaptureResult() }
}

/// Reports one word at the chunk's first loud sample.
private final class WordTranscriber: TimedSpeechTranscribing {
    func transcribeTimed(
        samples: [Float], model: any TranscriptionModel, context: TranscriptionRequestContext
    ) async throws -> [TimedTranscriptSegment] {
        guard let loud = samples.firstIndex(where: { abs($0) > 0.1 }) else { return [] }
        let start = Double(loud) / 16_000
        return [TimedTranscriptSegment(
            text: "here", start: start, end: start + 0.3, words: [TimedTranscriptWord(text: "here", start: start, end: start + 0.3)]
        )]
    }

    func speechRegions(in samples: [Float]) async throws -> [Range<Int>]? { nil }
    func releaseResources() async {}
}

@MainActor
final class FakeAnnotationInput: AnnotationInputCapturing {
    var strokes: [AnnotationStroke] = []
    var events: [AnnotationEvent] = []
    var displaySize = CGSize(width: 1_512, height: 982)
    private(set) var startedDisplay: CGDirectDisplayID?
    private(set) var stopCount = 0
    private(set) var isPenEnabled = false

    func start(displayID: CGDirectDisplayID, startNanoseconds: UInt64) { startedDisplay = displayID }
    func setPenEnabled(_ isEnabled: Bool) { isPenEnabled = isEnabled }

    func stop() -> (strokes: [AnnotationStroke], events: [AnnotationEvent], displaySize: CGSize) {
        stopCount += 1
        return (strokes, events, displaySize)
    }
}
