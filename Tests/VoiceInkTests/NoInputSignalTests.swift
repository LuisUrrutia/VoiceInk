import Combine
import CoreAudio
import XCTest
import os

@testable import VoiceInk

final class NoInputSignalDetectorTests: XCTestCase {
    private static let measuredQuietRoomPeakDBFS: Float = -66.6

    func testDigitalSilenceWarnsAfterOneAndAHalfSeconds() {
        var detector = NoInputSignalDetector(startedAt: ms(0))

        feed(&detector, peak: -120, from: 0, through: 1_490)
        XCTAssertFalse(detector.isWarning)
        feed(&detector, peak: -120, from: 1_500, through: 1_500)

        XCTAssertTrue(detector.isWarning)
    }

    func testInputThatDeliversNoBuffersWarns() {
        var detector = NoInputSignalDetector(startedAt: ms(0))

        for time in stride(from: 0, through: 1_500, by: 100) {
            detector.observe(peakDBFS: -160, capturedThrough: nil, inputID: 1, at: ms(time))
        }

        XCTAssertTrue(detector.isWarning)
    }

    func testStalledBuffersReadAsSilentEvenWithAnOldLoudPeak() {
        var detector = NoInputSignalDetector(startedAt: ms(0))
        detector.observe(peakDBFS: -20, capturedThrough: ms(0), inputID: 1, at: ms(0))

        for time in stride(from: 100, through: 1_600, by: 100) {
            detector.observe(peakDBFS: -20, capturedThrough: ms(0), inputID: 1, at: ms(time))
        }

        XCTAssertTrue(detector.isWarning)
    }

    func testQuietWorkingMicrophonesNeverWarn() {
        for peak in [Self.measuredQuietRoomPeakDBFS, -75, NoInputSignalDetector.heardPeakDBFS] {
            var detector = NoInputSignalDetector(startedAt: ms(0))

            feed(&detector, peak: peak, from: 0, through: 10_000)

            XCTAssertFalse(detector.isWarning, "peak \(peak) dBFS")
        }
    }

    func testReturningLevelHidesTheWarningAndItDoesNotReturnForTheSameInput() {
        var detector = NoInputSignalDetector(startedAt: ms(0))
        feed(&detector, peak: -120, from: 0, through: 1_500)
        XCTAssertTrue(detector.isWarning)

        feed(&detector, peak: -40, from: 1_600, through: 1_600)
        XCTAssertFalse(detector.isWarning)
        feed(&detector, peak: -120, from: 1_700, through: 6_000)

        XCTAssertFalse(detector.isWarning)
    }

    func testLevelBeforeTheDeadlineRestartsTheQuietPeriod() {
        var detector = NoInputSignalDetector(startedAt: ms(0))
        feed(&detector, peak: -120, from: 0, through: 1_400)
        feed(&detector, peak: -50, from: 1_450, through: 1_450)

        feed(&detector, peak: -120, from: 1_500, through: 2_900)
        XCTAssertFalse(detector.isWarning)
        feed(&detector, peak: -120, from: 2_950, through: 2_950)

        XCTAssertTrue(detector.isWarning)
    }

    func testANewInputHidesTheWarningAndIsEvaluatedAgain() {
        var detector = NoInputSignalDetector(startedAt: ms(0))
        feed(&detector, peak: -120, from: 0, through: 1_500)
        XCTAssertTrue(detector.isWarning)
        feed(&detector, peak: -40, from: 1_600, through: 1_600)

        feed(&detector, peak: -120, inputID: 2, from: 1_700, through: 1_700)
        XCTAssertFalse(detector.isWarning)
        feed(&detector, peak: -120, inputID: 2, from: 1_800, through: 3_100)
        XCTAssertFalse(detector.isWarning)
        feed(&detector, peak: -120, inputID: 2, from: 3_200, through: 3_200)

        XCTAssertTrue(detector.isWarning)
    }

    private func feed(
        _ detector: inout NoInputSignalDetector, peak: Float, inputID: AudioDeviceID = 1, from start: Int, through end: Int
    ) {
        for time in stride(from: start, through: end, by: 10) {
            detector.observe(peakDBFS: peak, capturedThrough: ms(time), inputID: inputID, at: ms(time))
        }
    }

    private func ms(_ milliseconds: Int) -> UInt64 { 1_000_000_000 + UInt64(milliseconds) * 1_000_000 }
}

@MainActor
final class NoInputSignalRecorderTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var announcements: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "NoInputSignalRecorderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.custom.rawValue
        defaults.selectedAudioDeviceUID = "dead-mic"
        announcements = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDeadInputWarnsOnceAndKeepsRecording() async throws {
        let (recorder, hardware, _) = makeRecorder()

        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        await waitUntil { recorder.isInputSilent }
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(announcements, [String(localized: "No sound. Pick another mic?")])
        XCTAssertEqual(hardware.events, ["start:1"])
        await recorder.stopRecording()
    }

    func testQuietWorkingInputDoesNotWarn() async throws {
        let (recorder, hardware, _) = makeRecorder()
        hardware.level = -66.6

        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(recorder.isInputSilent)
        XCTAssertTrue(announcements.isEmpty)
        await recorder.stopRecording()
    }

    func testReturningLevelHidesTheWarning() async throws {
        let (recorder, hardware, _) = makeRecorder()
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        await waitUntil { recorder.isInputSilent }

        hardware.level = -45

        await waitUntil { !recorder.isInputSilent }
        await recorder.stopRecording()
    }

    func testStopClearsTheWarningAndRestartEvaluatesAgain() async throws {
        let (recorder, hardware, _) = makeRecorder()
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        await waitUntil { recorder.isInputSilent }

        await recorder.stopRecording()
        XCTAssertFalse(recorder.isInputSilent)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(recorder.isInputSilent)

        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        XCTAssertFalse(recorder.isInputSilent)
        await waitUntil { recorder.isInputSilent }

        XCTAssertEqual(announcements.count, 2)
        XCTAssertEqual(hardware.events, ["start:1", "stop", "start:1"])
        await recorder.stopRecording()
    }

    func testMicrophoneTestDoesNotWarn() async throws {
        let (recorder, _, _) = makeRecorder()

        try await recorder.startMicrophoneTest(toOutputFile: temporaryWAV())
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertFalse(recorder.isInputSilent)
        XCTAssertTrue(announcements.isEmpty)
        await recorder.stopRecording()
    }

    func testPickingAnotherMicrophoneSwitchesTheRecordingWithoutANewFile() async throws {
        let (recorder, hardware, devices) = makeRecorder()
        var warnings: [Bool] = []
        let observation = recorder.$isInputSilent.removeDuplicates().dropFirst().sink { warnings.append($0) }
        defer { observation.cancel() }
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        await waitUntil { recorder.isInputSilent }

        let menu = QuickMicrophoneMenu.make(devices: devices)
        menu.performActionForItem(at: try XCTUnwrap(menu.items.firstIndex { $0.title == "USB" }))

        await waitUntil { devices.activeRecordingDeviceID == 2 }
        // The silent new input clears the warning for only one quiet period, which a late poll can miss.
        await waitUntil { warnings == [true, false, true] }
        XCTAssertEqual(hardware.events, ["start:1", "switch:2"])
        XCTAssertEqual(devices.temporaryMicrophone?.uid, "usb-mic")
        XCTAssertEqual(defaults.selectedAudioDeviceUID, "dead-mic")
        XCTAssertEqual(announcements.count, 2)

        await recorder.stopRecording()
        XCTAssertEqual(hardware.events, ["start:1", "switch:2", "stop"])
    }

    func testMenuMarksTheRecordingInputAndDisablesUnusableInputs() async throws {
        let (recorder, _, devices) = makeRecorder()
        devices.closedLidInternalMicrophoneID = 2
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)

        let items = QuickMicrophoneMenu.make(devices: devices).items

        XCTAssertEqual(items.map(\.title), [String(localized: "Use Microphone Temporarily"), "Dead Input", "USB"])
        XCTAssertTrue(items[0].isSectionHeader)
        XCTAssertEqual(items[1].state, .on)
        XCTAssertTrue(items[1].isEnabled)
        XCTAssertEqual(items[2].state, .off)
        XCTAssertFalse(items[2].isEnabled)
        await recorder.stopRecording()
    }

    func testResumingAutomaticSelectionFromTheMenuMovesTheRecording() async throws {
        let (recorder, hardware, devices) = makeRecorder()
        devices.selectTemporaryMicrophone(id: 2)
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)
        XCTAssertEqual(devices.activeRecordingDeviceID, 2)

        let menu = QuickMicrophoneMenu.make(devices: devices)
        XCTAssertEqual(menu.items.first?.title, String(localized: "Resume Automatic Selection"))
        menu.performActionForItem(at: 0)

        await waitUntil { devices.activeRecordingDeviceID == 1 }
        XCTAssertNil(devices.temporaryMicrophone)
        XCTAssertEqual(hardware.events, ["start:2", "switch:1"])
        await recorder.stopRecording()
    }

    func testPickingTheActiveMicrophoneRequestsNoSwitch() async throws {
        let (recorder, hardware, devices) = makeRecorder()
        try await recorder.startRecording(toOutputFile: temporaryWAV(), applyRecordingEffects: false)

        devices.selectTemporaryMicrophone(id: 1)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(hardware.events, ["start:1"])
        XCTAssertFalse(devices.recordingDeviceSession.isDeviceChangePending)
        await recorder.stopRecording()
    }

    private func makeRecorder() -> (Recorder, SilentInputHardware, SilentInputDevices) {
        let devices = SilentInputDevices(userDefaults: defaults)
        let hardware = SilentInputHardware()
        let recorder = Recorder(
            hardware: hardware, deviceManager: devices, defaults: defaults,
            inputSignalMonitoring: InputSignalMonitoring(
                pollInterval: .milliseconds(5), quietDurationNanoseconds: 60_000_000,
                announce: { [weak self] in self?.announcements.append($0) }
            )
        )
        return (recorder, hardware, devices)
    }

    private func temporaryWAV() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool
    ) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out", file: file, line: line)
    }
}

private final class SilentInputDevices: AudioDeviceManager {
    var closedLidInternalMicrophoneID: AudioDeviceID?

    init(userDefaults: UserDefaults) {
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override var isClamshellClosed: Bool { closedLidInternalMicrophoneID != nil }
    override func startMonitoring() {}

    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(1, "dead-mic", "Dead Input"), (2, "usb-mic", "USB")]
        completion?()
    }

    override func getSystemDefaultDevice() -> AudioDeviceID? { 1 }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { deviceID == closedLidInternalMicrophoneID }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func inputTransport(_ deviceID: AudioDeviceID) -> AudioInputTransport { .other }
}

/// Delivers a buffer at every meter read while capturing, at `level` dBFS.
private final class SilentInputHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var level: Float = -120
        var capturing = false
        var events: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var onAudioChunk: ((Data) -> Void)?
    var averagePower: Float { peakPower }
    var peakPower: Float { state.withLock { $0.capturing ? $0.level : -160 } }
    var capturedThroughNanoseconds: UInt64? {
        state.withLock { $0.capturing ? DispatchTime.now().uptimeNanoseconds : nil }
    }

    var level: Float {
        get { state.withLock { $0.level } }
        set { state.withLock { $0.level = newValue } }
    }

    var events: [String] { state.withLock { $0.events } }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        state.withLock {
            $0.capturing = true
            $0.events.append("start:\(deviceID)")
        }
    }

    func stopRecording() {
        state.withLock {
            $0.capturing = false
            $0.events.append("stop")
        }
    }

    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        state.withLock { $0.events.append("switch:\(deviceID)") }
    }

    func invalidatePreparation() {}
    func teardown() {}
}
