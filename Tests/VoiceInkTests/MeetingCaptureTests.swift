import CoreAudio
import IOKit.pwr_mgt
import XCTest
import os

@testable import VoiceInk

@MainActor final class MeetingCaptureTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCaptureTests-\(UUID().uuidString)")
        suiteName = "MeetingCaptureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        Labs.setEnabled(true, for: .meetings, in: defaults)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Timeline

    func testTimelineMapsContinuousAudioFromOneAnchor() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0.5)
        timeline.record(frame: 16_000, at: 1.5)
        timeline.record(frame: 32_000, at: 2.5)

        XCTAssertEqual(timeline.anchors.count, 1)
        XCTAssertEqual(timeline.time(forFrame: 24_000), 2.0, accuracy: 0.0001)
    }

    func testTimelineStartsAnAnchorAfterAGap() {
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0)
        timeline.record(frame: 16_000, at: 4)

        XCTAssertEqual(timeline.anchors.count, 2)
        XCTAssertEqual(timeline.time(forFrame: 8_000), 0.5, accuracy: 0.0001)
        XCTAssertEqual(timeline.time(forFrame: 24_000), 4.5, accuracy: 0.0001)
    }

    func testTimelineReanchorsPeriodicallyToAbsorbDrift() {
        var timeline = MeetingTrackTimeline()
        for second in 0...12 {
            // A clock 1 % slow stays inside the gap tolerance between anchors.
            timeline.record(frame: second * 16_000, at: Double(second) * 1.01)
        }

        XCTAssertEqual(timeline.anchors.map(\.frame), [0, 80_000, 160_000])
        XCTAssertEqual(timeline.time(forFrame: 192_000), 12.1, accuracy: 0.0001)
    }

    // MARK: - Recorder

    func testStartRequiresTheLabsSwitchAndMicrophoneAccess() async {
        Labs.setEnabled(false, for: .meetings, in: defaults)
        let fixture = makeRecorder()

        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start(), MeetingRecorderError.featureDisabled)

        Labs.setEnabled(true, for: .meetings, in: defaults)
        let denied = makeRecorder(isMicrophoneAuthorized: false)
        await XCTAssertThrowsErrorAsync(try await denied.recorder.start(), MeetingRecorderError.microphoneNotAuthorized)
        XCTAssertEqual(fixture.systemAudio.startCount + denied.systemAudio.startCount, 0)
    }

    func testUndecidedSystemAudioAsksOnceAndDeniedRefusesToRecord() async throws {
        let fixture = makeRecorder(permission: .notDetermined, answer: .denied)

        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start(), MeetingRecorderError.systemAudioDenied)

        XCTAssertEqual(fixture.permission.requestCount, 1)
        XCTAssertEqual(fixture.systemAudio.startCount, 0)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testMeetingRecordsBothTracksAndHoldsIdleSleepUntilStop() async throws {
        let fixture = makeRecorder()

        try await fixture.recorder.start(title: "Standup", provider: "zoom")
        let id = try XCTUnwrap(fixture.recorder.activeMeeting?.id)
        fixture.clock.advance(seconds: 1)
        fixture.microphone.emit(frames: 16_000, capturedThrough: fixture.clock.now)
        fixture.clock.advance(seconds: 2)
        let recorded = await fixture.recorder.stop()

        let manifest = try XCTUnwrap(recorded)
        XCTAssertEqual(manifest.status, .recorded)
        XCTAssertEqual(manifest.title, "Standup")
        XCTAssertEqual(manifest.provider, "zoom")
        XCTAssertEqual(manifest.duration, 3, accuracy: 0.001)
        XCTAssertEqual(manifest.track(.system)?.timeline.anchors.first?.time, 0.25)
        XCTAssertEqual(manifest.track(.microphone)?.timeline.time(forFrame: 0) ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(manifest.track(.microphone)?.heardSignal, true)
        XCTAssertEqual(fixture.systemAudio.url, fixture.store.audioURL(for: id, track: .system))
        XCTAssertEqual(fixture.microphone.startedURL, fixture.store.audioURL(for: id, track: .microphone))
        XCTAssertEqual(try fixture.store.load(id: id), manifest)
        XCTAssertEqual(fixture.recorder.meetings.map(\.id), [id])
        await waitForSleepQueue(fixture.sleepQueue)
        XCTAssertEqual(fixture.power.createdNames, [MeetingRecorder.assertionName])
        XCTAssertTrue(fixture.power.liveAssertions.isEmpty)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.microphone.stopCount, 1)
    }

    func testDictationDuringAMeetingIsRecordedAsAnInterval() async throws {
        let fixture = makeRecorder()
        XCTAssertFalse(fixture.recorder.suppressesDictationOutputEffects)
        try await fixture.recorder.start()
        XCTAssertTrue(fixture.recorder.suppressesDictationOutputEffects)

        fixture.clock.advance(seconds: 10)
        fixture.recorder.dictationCaptureBegan()
        fixture.clock.advance(seconds: 4)
        fixture.recorder.dictationCaptureEnded()
        fixture.clock.advance(seconds: 1)
        fixture.recorder.dictationCaptureBegan()
        fixture.clock.advance(seconds: 2)
        let stopped = await fixture.recorder.stop()
        let manifest = try XCTUnwrap(stopped)

        XCTAssertEqual(manifest.dictationIntervals, [.init(start: 10, end: 14), .init(start: 15, end: 17)])
        XCTAssertFalse(fixture.recorder.suppressesDictationOutputEffects)
        fixture.recorder.dictationCaptureBegan()
        fixture.recorder.dictationCaptureEnded()
        XCTAssertEqual(try fixture.store.load(id: manifest.id).dictationIntervals.count, 2)
    }

    func testAStalledSystemTapIsRestartedWhileTheMeetingRecords() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()
        fixture.systemAudio.lastDelivery = fixture.clock.now
        fixture.clock.advance(seconds: 4)

        try await waitUntil { fixture.systemAudio.restartCount > 0 }
        _ = await fixture.recorder.stop()
        let restarts = fixture.systemAudio.restartCount
        fixture.clock.advance(seconds: 10)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(fixture.systemAudio.restartCount, restarts)
    }

    func testMicrophoneFailureStopsTheSystemTapAndRecordsTheFailure() async throws {
        let fixture = makeRecorder()
        fixture.microphone.failStart = true

        await XCTAssertThrowsErrorAsync(try await fixture.recorder.start())

        XCTAssertEqual(fixture.systemAudio.stopCount, 1)
        XCTAssertEqual(fixture.recorder.meetings.first?.status, .failed)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testMicrophoneFollowsTheResolvedInputWithoutANewFile() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()
        fixture.devices.defaultDevice = 72

        await fixture.recorder.activeMicrophone?.switchToResolvedDevice()
        _ = await fixture.recorder.stop()

        XCTAssertEqual(fixture.microphone.startedDevice, 71)
        XCTAssertEqual(fixture.microphone.switchedDevices, [72])
        XCTAssertEqual(fixture.microphone.startCount, 1)
    }

    func testTurningMeetingsOffStopsTheRecording() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()

        Labs.setEnabled(false, for: .meetings, in: defaults)

        try await waitUntil { !fixture.recorder.isRecording }
        XCTAssertEqual(fixture.recorder.meetings.first?.status, .recorded)
    }

    func testTerminationClosesBothFilesAndLeavesTheMeetingInterrupted() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()
        let id = try XCTUnwrap(fixture.recorder.activeMeeting?.id)

        fixture.recorder.closeForTermination()

        XCTAssertEqual(try fixture.store.load(id: id).status, .interrupted)
        XCTAssertEqual(fixture.systemAudio.stopCount, 1)
        XCTAssertEqual(fixture.microphone.stopCount, 1)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testDictationRecorderReportsDictationsButNotTheMicrophoneTest() async throws {
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let coordinator = RecordingCoordinatorSpy()
        let hardware = FakeMeetingMicrophoneHardware()
        let recorder = Recorder(
            hardware: hardware, deviceManager: devices, defaults: defaults, isMicrophoneAuthorized: { true },
            meetingCoordinator: coordinator
        )
        let directory = root.appendingPathComponent("dictation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try await recorder.startRecording(toOutputFile: directory.appendingPathComponent("a.wav"))
        await recorder.stopRecording()
        try await recorder.startMicrophoneTest(toOutputFile: directory.appendingPathComponent("b.wav"))
        await recorder.stopRecording()

        XCTAssertEqual(coordinator.events, ["began", "ended"])
    }

    func testMeetingPreferencesRoundTripThroughBackups() {
        MeetingSettings.setOutputFolder(URL(fileURLWithPath: "/tmp/Meetings"), in: defaults)
        defaults.set(false, forKey: MeetingSettings.showsRecordingIndicatorKey)
        let backup = MeetingSettings.Backup.capture(from: defaults)
        let restored = UserDefaults(suiteName: "\(suiteName!).restored")!
        defer { restored.removePersistentDomain(forName: "\(suiteName!).restored") }

        backup.restore(in: restored)
        MeetingSettings.Backup().restore(in: restored)

        XCTAssertEqual(MeetingSettings.outputFolder(in: restored).path, "/tmp/Meetings")
        XCTAssertFalse(MeetingSettings.showsRecordingIndicator(in: restored))
        MeetingSettings.Backup(outputFolder: "relative/path").restore(in: restored)
        XCTAssertEqual(MeetingSettings.outputFolder(in: restored).path, "/tmp/Meetings")
    }

    func testTurningMeetingsOffWhileConsentIsPendingCancelsTheStart() async throws {
        let fixture = makeRecorder(permission: .notDetermined, answer: .granted)
        fixture.permission.holdsAnswer = true
        let start = Task { try await fixture.recorder.start() }
        try await waitUntil { fixture.permission.requestCount == 1 }

        Labs.setEnabled(false, for: .meetings, in: defaults)
        try await Task.sleep(for: .milliseconds(20))
        fixture.permission.answerRequest()

        await XCTAssertThrowsErrorAsync(try await start.value, MeetingRecorderError.featureDisabled)
        XCTAssertEqual(fixture.systemAudio.startCount, 0)
        XCTAssertFalse(fixture.recorder.isRecording)
    }

    func testTurningMeetingsOffWhileTheMicrophoneStartsClosesBothTracks() async throws {
        let fixture = makeRecorder()
        fixture.microphone.holdStart = true
        let start = Task { try await fixture.recorder.start() }
        try await waitUntil { fixture.systemAudio.startCount == 1 }

        Labs.setEnabled(false, for: .meetings, in: defaults)
        try await Task.sleep(for: .milliseconds(20))
        fixture.microphone.releaseStart()

        await XCTAssertThrowsErrorAsync(try await start.value, MeetingRecorderError.featureDisabled)
        XCTAssertFalse(fixture.recorder.isRecording)
        XCTAssertEqual(fixture.systemAudio.stopCount, 1)
        XCTAssertEqual(fixture.microphone.stopCount, 1)
        XCTAssertTrue(fixture.recorder.meetings.isEmpty)
        XCTAssertTrue(fixture.store.loadAll().isEmpty)
    }

    func testMicrophoneFramesTakeTheirOwnBlocksCaptureTime() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()
        fixture.clock.advance(seconds: 2)
        // One 4,096-frame block captured during the first 0.256 s, converted in four chunks and delivered late.
        fixture.microphone.emit(frames: 4_096, capturedThrough: fixture.clock.now - 1_744_000_000, chunks: 4)
        fixture.microphone.emit(frames: 4_096, capturedThrough: fixture.clock.now - 1_488_000_000, chunks: 4)
        let stopped = await fixture.recorder.stop()

        let timeline = try XCTUnwrap(stopped?.track(.microphone)?.timeline)
        XCTAssertEqual(timeline.time(forFrame: 0), 0, accuracy: 0.001)
        XCTAssertEqual(timeline.time(forFrame: 8_192), 0.512, accuracy: 0.001)
        XCTAssertEqual(timeline.anchors.count, 1)
    }

    func testMicrophoneBlockAfterAGapStartsANewAnchor() async throws {
        let fixture = makeRecorder()
        try await fixture.recorder.start()
        let start = fixture.clock.now
        fixture.microphone.emit(frames: 1_600, capturedThrough: start + 100_000_000)
        fixture.microphone.emit(frames: 1_600, capturedThrough: start + 1_100_000_000)
        let stopped = await fixture.recorder.stop()

        let timeline = try XCTUnwrap(stopped?.track(.microphone)?.timeline)
        XCTAssertEqual(timeline.time(forFrame: 800), 0.05, accuracy: 0.001)
        XCTAssertEqual(timeline.time(forFrame: 1_600), 1.0, accuracy: 0.001)
        XCTAssertEqual(timeline.time(forFrame: 2_400), 1.05, accuracy: 0.001)
    }

    func testAMeetingStartingDuringADictationCancelsItsPendingMute() async throws {
        let directory = root.appendingPathComponent("overlap", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let coordinator = RecordingCoordinatorSpy()
        coordinator.suppresses = false
        var quiets = 0
        let recorder = Recorder(
            hardware: FakeMeetingMicrophoneHardware(), deviceManager: MeetingAudioDevices(userDefaults: defaults),
            defaults: defaults, isMicrophoneAuthorized: { true }, meetingCoordinator: coordinator,
            outputEffects: RecordingOutputEffects(pauseMedia: { _ in }, quietOutput: { _ in quiets += 1 })
        )
        try await recorder.startRecording(toOutputFile: directory.appendingPathComponent("a.wav"))

        try await Task.sleep(for: .milliseconds(50))
        coordinator.suppresses = true
        NotificationCenter.default.post(name: MeetingRecorder.willStartNotification, object: nil)
        try await Task.sleep(for: .milliseconds(400))
        await recorder.stopRecording()

        XCTAssertEqual(quiets, 0)
    }

    func testAMeetingStartingAfterADictationQuietedOutputRestoresIt() async throws {
        let directory = root.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = makeRecorder()
        let coordinator = RecordingCoordinatorSpy()
        coordinator.suppresses = false
        var quieted: [UUID] = []
        var restored: [UUID] = []
        var resumed: [UUID] = []
        let recorder = Recorder(
            hardware: FakeMeetingMicrophoneHardware(), deviceManager: MeetingAudioDevices(userDefaults: defaults),
            defaults: defaults, isMicrophoneAuthorized: { true }, meetingCoordinator: coordinator,
            outputEffects: RecordingOutputEffects(
                pauseMedia: { _ in }, quietOutput: { quieted.append($0) },
                restoreOutput: { restored.append($0) }, resumeMedia: { resumed.append($0) }
            )
        )
        try await recorder.startRecording(toOutputFile: directory.appendingPathComponent("a.wav"))
        try await waitUntil { quieted.count == 1 }

        coordinator.suppresses = true
        try await fixture.recorder.start()
        try await waitUntil { resumed.count == 1 }

        XCTAssertEqual(restored, quieted)
        XCTAssertEqual(resumed, quieted)
        await recorder.stopRecording()
        _ = await fixture.recorder.stop()
    }

    func testAVisibleRecorderPanelUpdatesTheMeetingReservationWhenTheSwitchChanges() async throws {
        let ui = RecorderUIManager()
        let panel = RecorderPanelShortcutManager(recorderUIManager: ui, defaults: defaults)
        ui.isRecorderPanelVisible = true
        try await waitUntil { panel.reservedActions.contains(.toggleMeeting) }

        Labs.setEnabled(false, for: .meetings, in: defaults)
        try await waitUntil { !panel.reservedActions.contains(.toggleMeeting) }
        Labs.setEnabled(true, for: .meetings, in: defaults)
        try await waitUntil { panel.reservedActions.contains(.toggleMeeting) }
        ui.isRecorderPanelVisible = false
    }

    func testDictationAlreadyCapturingWhenTheMeetingStartsIsExcludedFromItsStart() async throws {
        let fixture = makeRecorder()
        fixture.recorder.dictationCaptureBegan()
        fixture.clock.advance(seconds: 2)
        try await fixture.recorder.start()
        fixture.clock.advance(seconds: 3)
        fixture.recorder.dictationCaptureEnded()
        fixture.clock.advance(seconds: 1)

        let stopped = await fixture.recorder.stop()

        XCTAssertEqual(stopped?.dictationIntervals, [.init(start: 0, end: 3)])
    }

    func testDictationThatEndsWhileTheMeetingStartsIsKept() async throws {
        let fixture = makeRecorder()
        fixture.microphone.holdStart = true
        let start = Task { try await fixture.recorder.start() }
        try await waitUntil { fixture.systemAudio.startCount == 1 }
        fixture.clock.advance(seconds: 1)
        fixture.recorder.dictationCaptureBegan()
        fixture.clock.advance(seconds: 2)
        fixture.recorder.dictationCaptureEnded()
        fixture.microphone.releaseStart()
        try await start.value

        let stopped = await fixture.recorder.stop()

        XCTAssertEqual(stopped?.dictationIntervals, [.init(start: 1, end: 3)])
    }

    func testMeetingShortcutIsMonitoredOnlyWhileMeetingsIsOn() {
        XCTAssertTrue(ShortcutAction.activeGlobalUtilityActions(defaults: defaults).contains(.toggleMeeting))

        Labs.setEnabled(false, for: .meetings, in: defaults)

        XCTAssertFalse(ShortcutAction.activeGlobalUtilityActions(defaults: defaults).contains(.toggleMeeting))
        XCTAssertEqual(
            ShortcutAction.activeGlobalUtilityActions(defaults: defaults),
            ShortcutAction.globalUtilityActions.filter { $0 != .toggleMeeting }
        )
        Labs.setEnabled(true, for: .meetings, in: defaults)
        XCTAssertEqual(ShortcutAction.activeGlobalUtilityActions(defaults: defaults), ShortcutAction.globalUtilityActions)
    }

    func testDictationLeavesOutputAndMediaAloneOnlyWhileAMeetingRecords() async throws {
        let directory = root.appendingPathComponent("effects", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let duringMeeting = try await recordDictation(meetingRecords: true, to: directory.appendingPathComponent("a.wav"))
        let withoutMeeting = try await recordDictation(meetingRecords: false, to: directory.appendingPathComponent("b.wav"))

        XCTAssertEqual(duringMeeting, OutputEffectCalls(pauses: 0, quiets: 0))
        XCTAssertEqual(withoutMeeting, OutputEffectCalls(pauses: 1, quiets: 1))
    }

    private func recordDictation(meetingRecords: Bool, to url: URL) async throws -> OutputEffectCalls {
        let coordinator = RecordingCoordinatorSpy()
        coordinator.suppresses = meetingRecords
        var calls = OutputEffectCalls()
        let recorder = Recorder(
            hardware: FakeMeetingMicrophoneHardware(), deviceManager: MeetingAudioDevices(userDefaults: defaults),
            defaults: defaults, isMicrophoneAuthorized: { true }, meetingCoordinator: coordinator,
            outputEffects: RecordingOutputEffects(pauseMedia: { _ in calls.pauses += 1 }, quietOutput: { _ in calls.quiets += 1 })
        )
        try await recorder.startRecording(toOutputFile: url)
        // Output is quieted 220 ms after the start.
        try await Task.sleep(for: .milliseconds(400))
        await recorder.stopRecording()
        return calls
    }

    // MARK: - Fixture

    private struct Fixture {
        let recorder: MeetingRecorder
        let store: MeetingStore
        let systemAudio: FakeSystemAudioCapture
        let microphone: FakeMeetingMicrophoneHardware
        let devices: MeetingAudioDevices
        let permission: FakeSystemAudioPermission
        let power: MeetingPowerAssertions
        let sleepQueue: DispatchQueue
        let clock: MeetingTestClock
    }

    private func makeRecorder(
        permission status: SystemAudioAuthorization = .granted, answer: SystemAudioAuthorization = .granted,
        isMicrophoneAuthorized: Bool = true
    ) -> Fixture {
        let store = MeetingStore(rootURL: root, movesToTrash: false)
        let systemAudio = FakeSystemAudioCapture()
        let hardware = FakeMeetingMicrophoneHardware()
        let devices = MeetingAudioDevices(userDefaults: defaults)
        let permission = FakeSystemAudioPermission(status: status, answer: answer)
        let power = MeetingPowerAssertions()
        let sleepQueue = DispatchQueue(label: "MeetingCaptureTests.sleep")
        let clock = MeetingTestClock()
        systemAudio.clock = clock
        var dependencies = MeetingRecorder.Dependencies()
        dependencies.store = store
        dependencies.permission = permission
        dependencies.makeSystemAudio = { systemAudio }
        dependencies.makeMicrophone = { MeetingMicrophoneCapture(deviceManager: devices, makeHardware: { hardware }) }
        dependencies.isMicrophoneAuthorized = { isMicrophoneAuthorized }
        dependencies.idleSleep = IdleSleepPrevention(client: power, queue: sleepQueue)
        dependencies.now = { clock.now }
        dependencies.defaults = defaults
        dependencies.stallCheckInterval = .milliseconds(5)
        return Fixture(
            recorder: MeetingRecorder(dependencies: dependencies), store: store, systemAudio: systemAudio,
            microphone: hardware, devices: devices, permission: permission, power: power, sleepQueue: sleepQueue,
            clock: clock
        )
    }

    private func waitForSleepQueue(_ queue: DispatchQueue) async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    private func waitUntil(timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not met in time") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Fakes

private final class MeetingTestClock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock<UInt64>(initialState: 1_000_000_000_000)
    var now: UInt64 { value.withLock { $0 } }
    func advance(seconds: Double) { value.withLock { $0 += UInt64(seconds * 1_000_000_000) } }
}

private final class FakeSystemAudioCapture: SystemAudioCapturing, @unchecked Sendable {
    private struct State {
        var url: URL?
        var startCount = 0
        var restartCount = 0
        var stopCount = 0
        var lastDelivery: UInt64?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var clock: MeetingTestClock?

    var url: URL? { state.withLock { $0.url } }
    var startCount: Int { state.withLock { $0.startCount } }
    var restartCount: Int { state.withLock { $0.restartCount } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var lastDelivery: UInt64? {
        get { state.withLock { $0.lastDelivery } }
        set { state.withLock { $0.lastDelivery = newValue } }
    }
    var lastDeliveryNanoseconds: UInt64? { lastDelivery ?? clock?.now }

    func start(writingTo url: URL, meetingStartNanoseconds: UInt64) throws {
        FileManager.default.createFile(atPath: url.path, contents: Data())
        state.withLock {
            $0.url = url
            $0.startCount += 1
        }
    }

    func restart() throws {
        state.withLock {
            $0.restartCount += 1
            $0.lastDelivery = nil
        }
    }

    func stop() -> MeetingTrackCaptureResult {
        state.withLock { $0.stopCount += 1 }
        var timeline = MeetingTrackTimeline()
        timeline.record(frame: 0, at: 0.25)
        return MeetingTrackCaptureResult(timeline: timeline, heardSignal: true)
    }
}

private final class FakeSystemAudioPermission: SystemAudioAuthorizing, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(status: SystemAudioAuthorization, requests: Int)>
    private let answer: SystemAudioAuthorization
    /// When set, `request()` waits for `answerRequest()`.
    var holdsAnswer = false
    private var pendingAnswer: CheckedContinuation<Void, Never>?

    @MainActor func answerRequest() {
        pendingAnswer?.resume()
        pendingAnswer = nil
    }

    init(status: SystemAudioAuthorization, answer: SystemAudioAuthorization) {
        state = OSAllocatedUnfairLock(initialState: (status, 0))
        self.answer = answer
    }

    var requestCount: Int { state.withLock { $0.requests } }

    func status() -> SystemAudioAuthorization { state.withLock { $0.status } }

    func request() async -> SystemAudioAuthorization {
        state.withLock { $0.requests += 1 }
        if holdsAnswer {
            await withCheckedContinuation { continuation in
                Task { @MainActor in self.pendingAnswer = continuation }
            }
        }
        state.withLock { $0.status = answer }
        return answer
    }
}

private final class MeetingPowerAssertions: PowerAssertionClient, @unchecked Sendable {
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

final class FakeMeetingMicrophoneHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var callback: ((Data) -> Void)?
        var startedURL: URL?
        var startedDevice: AudioDeviceID?
        var switchedDevices: [AudioDeviceID] = []
        var startCount = 0
        var stopCount = 0
        var capturedThrough: UInt64?
        var failStart = false
        var progress: ((Int, UInt64) -> Void)?
        var writtenFrames = 0
    }

    /// When set, `startRecording` blocks the microphone queue until `releaseStart()`.
    let startGate = DispatchSemaphore(value: 0)
    private let holdsStart = OSAllocatedUnfairLock(initialState: false)
    var holdStart: Bool {
        get { holdsStart.withLock { $0 } }
        set { holdsStart.withLock { $0 = newValue } }
    }
    func releaseStart() { startGate.signal() }

    var onCaptureProgress: ((Int, UInt64) -> Void)? {
        get { state.withLock { $0.progress } }
        set { state.withLock { $0.progress = newValue } }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let averagePower: Float = -40
    let peakPower: Float = -20

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var capturedThroughNanoseconds: UInt64? { state.withLock { $0.capturedThrough } }
    var startedURL: URL? { state.withLock { $0.startedURL } }
    var startedDevice: AudioDeviceID? { state.withLock { $0.startedDevice } }
    var switchedDevices: [AudioDeviceID] { state.withLock { $0.switchedDevices } }
    var startCount: Int { state.withLock { $0.startCount } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var failStart: Bool {
        get { state.withLock { $0.failStart } }
        set { state.withLock { $0.failStart = newValue } }
    }

    /// Delivers one input block: its converted PCM in `chunks` callbacks, then its capture progress.
    func emit(frames: Int, capturedThrough: UInt64, chunks: Int = 1) {
        let (callback, progress, written) = state.withLock { state -> (((Data) -> Void)?, ((Int, UInt64) -> Void)?, Int) in
            state.capturedThrough = capturedThrough
            state.writtenFrames += frames
            return (state.callback, state.progress, state.writtenFrames)
        }
        for _ in 0..<chunks {
            var samples = [Int16](repeating: 0, count: frames / chunks)
            samples[samples.count / 2] = 1_000
            callback?(samples.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        progress?(written, capturedThrough)
    }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        if holdStart { startGate.wait() }
        try state.withLock { state in
            if state.failStart { throw CoreAudioRecorderError.deviceNotAvailable }
            state.startedURL = url
            state.startedDevice = deviceID
            state.startCount += 1
        }
    }

    func stopRecording() { state.withLock { $0.stopCount += 1 } }

    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        state.withLock { $0.switchedDevices.append(deviceID) }
    }

    func invalidatePreparation() {}
    func teardown() {}
}

final class MeetingAudioDevices: AudioDeviceManager {
    var defaultDevice: AudioDeviceID = 71 {
        didSet { objectWillChange.send() }
    }

    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 71, uid: "meeting-mic-a", name: "Meeting A"), (id: 72, uid: "meeting-mic-b", name: "Meeting B")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { defaultDevice }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
}

private struct OutputEffectCalls: Equatable {
    var pauses = 0
    var quiets = 0
}

@MainActor
private final class RecordingCoordinatorSpy: DictationMeetingCoordinating {
    var events: [String] = []
    var suppresses = true
    var suppressesDictationOutputEffects: Bool { suppresses }
    func dictationCaptureBegan() { events.append("began") }
    func dictationCaptureEnded() { events.append("ended") }
}

func XCTAssertThrowsErrorAsync<E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> Void, _ expected: E,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
}
