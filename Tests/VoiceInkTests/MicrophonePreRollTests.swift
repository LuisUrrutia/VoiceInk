import AVFoundation
import CoreAudio
import XCTest
import os

@testable import VoiceInk

final class PreRollBufferTests: XCTestCase {
    // 1 kHz keeps one frame per millisecond; the window is 450 frames.
    private let origin: UInt64 = 10_000_000_000

    func testIdleHistoryKeepsOnlyTheNewestWindow() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)

        append(&buffer, frames: 0..<2_000)

        XCTAssertEqual(buffer.frameCount, 450)
        let samples = buffer.take(pressNanoseconds: endOfFrame(1_999))
        XCTAssertEqual(samples, (1_550..<2_000).map(Float.init))
        XCTAssertEqual(buffer.frameCount, 0)
    }

    func testPendingPressRetainsAudioFromOneWindowBeforeThePressUntilStart() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)
        append(&buffer, frames: 0..<1_000)
        let press = endOfFrame(999)

        append(&buffer, frames: 1_000..<1_800, pendingPress: press)
        let samples = buffer.take(pressNanoseconds: press)

        XCTAssertEqual(samples, (550..<1_800).map(Float.init))
    }

    func testPendingPressRetentionIsBoundedAndLapses() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)
        append(&buffer, frames: 0..<1_000)
        let press = endOfFrame(999)

        append(&buffer, frames: 1_000..<3_000, pendingPress: press)
        XCTAssertEqual(buffer.frameCount, buffer.capacityFrames)
        XCTAssertEqual(buffer.capacityFrames, 2_450)
        append(&buffer, frames: 3_000..<3_500, pendingPress: press)

        XCTAssertEqual(buffer.frameCount, 450)
        XCTAssertEqual(buffer.take(pressNanoseconds: press), (3_050..<3_500).map(Float.init))
    }

    func testPressAfterTheNewestFrameIncludesOnlyAudioWithinTheWindowBeforeIt() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)
        append(&buffer, frames: 0..<1_000)

        let samples = buffer.take(pressNanoseconds: endOfFrame(999) + 100_000_000)

        XCTAssertEqual(samples, (650..<1_000).map(Float.init))
    }

    func testInterleavedChannelsSurviveWrapping() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 2)

        for start in stride(from: 0, to: 3_000, by: 10) {
            let samples = (start..<start + 10).flatMap { [Float($0), -Float($0)] }
            samples.withUnsafeBufferPointer {
                buffer.append($0, endNanoseconds: endOfFrame(start + 9), pendingPressNanoseconds: nil)
            }
        }

        let samples = buffer.take(pressNanoseconds: endOfFrame(2_999))
        XCTAssertEqual(samples, (2_550..<3_000).flatMap { [Float($0), -Float($0)] })
    }

    func testCaptureGapExpiresAudioByCaptureTime() {
        var buffer = PreRollBuffer(sampleRate: 1_000, channelCount: 1)
        append(&buffer, frames: 0..<1_000)

        append(&buffer, frames: 2_000..<2_010)
        let samples = buffer.take(pressNanoseconds: endOfFrame(2_009))

        XCTAssertEqual(samples, (2_000..<2_010).map(Float.init))
    }

    private func append(_ buffer: inout PreRollBuffer, frames: Range<Int>, pendingPress: UInt64? = nil) {
        for start in stride(from: frames.lowerBound, to: frames.upperBound, by: 10) {
            let samples = (start..<min(start + 10, frames.upperBound)).map(Float.init)
            samples.withUnsafeBufferPointer {
                buffer.append($0, endNanoseconds: endOfFrame(start + samples.count - 1), pendingPressNanoseconds: pendingPress)
            }
        }
    }

    private func endOfFrame(_ frame: Int) -> UInt64 { origin + UInt64(frame + 1) * 1_000_000 }
}

final class PreRollRecordingWriterTests: XCTestCase {
    func testPreRollEntersTheFreshConverterAheadOfLiveInputForBothFileAndStream() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PreRoll-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let rate = 48_000.0
        let block = 480
        let tone = (0..<Int(rate * 1.5)).map { Float(0.4 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        var buffer = PreRollBuffer(sampleRate: rate, channelCount: 1)
        var end: UInt64 = 5_000_000_000
        for start in stride(from: 0, to: 48_000, by: block) {
            end += 10_000_000
            tone[start..<start + block].withUnsafeBufferPointer {
                buffer.append($0, endNanoseconds: end, pendingPressNanoseconds: nil)
            }
        }
        let url = directory.appendingPathComponent("preroll.wav")
        let writer = try RecordingAudioWriter(url: url, sampleRate: rate, channelCount: 1)
        let stream = OSAllocatedUnfairLock(initialState: Data())
        writer.onAudioChunk = { data in stream.withLock { $0.append(data) } }

        let attached = try writer.appendPreRoll(from: &buffer, pressNanoseconds: end)
        for start in stride(from: 48_000, to: tone.count, by: block) {
            try tone[start..<start + block].withUnsafeBufferPointer {
                try writer.append($0, frameCount: UInt32(block), sampleRate: rate, channelCount: 1)
            }
        }
        try writer.finish()

        XCTAssertEqual(attached, 0.45, accuracy: 1 / rate)
        XCTAssertEqual(buffer.frameCount, 0)
        let reference = try ContinuousAudioConverter(sampleRate: rate, channelCount: 1)
        var expected = Data()
        let continuous = Array(tone[(48_000 - 21_600)...])
        try continuous.withUnsafeBufferPointer {
            try reference.append($0, frameCount: UInt32(continuous.count)) { expected.append($0) }
        }
        try reference.finish { expected.append($0) }
        XCTAssertEqual(stream.withLock { $0 }, expected)
        XCTAssertEqual(try wavPCM(url), expected)
    }

    private func wavPCM(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Data(bytes: buffer.int16ChannelData![0], count: Int(buffer.frameLength) * MemoryLayout<Int16>.size)
    }
}

@MainActor
final class IdleMicrophoneCaptureTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var authorized = true

    override func setUp() {
        super.setUp()
        suiteName = "IdleMicrophoneCaptureTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.audioInputModeRawValue = AudioInputMode.systemDefault.rawValue
        authorized = true
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testReleaseWhenIdleIsTheDefaultAndNeverOpensTheMicrophone() async {
        let (recorder, hardware, _) = makeRecorder()

        recorder.handleLifecycleEvent(.audioDeviceChanged)
        recorder.handleLifecycleEvent(.systemDidWake)
        recorder.handleLifecycleEvent(.applicationDidBecomeActive)
        await settle(recorder)

        XCTAssertFalse(defaults.keepMicrophoneReady)
        XCTAssertFalse(hardware.events.contains { $0.hasPrefix("idle:") })
    }

    func testSettingOpensTheEffectiveInputAndTurningItOffClosesIt() async {
        let (recorder, hardware, _) = makeRecorder()

        defaults.keepMicrophoneReady = true
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }
        defaults.keepMicrophoneReady = false

        await waitFor(recorder, hardware) { $0.lastIdleEvent == "stopIdle" }
    }

    func testSleepClosesTheIdleMicrophoneAndWakeReopensIt() async {
        let (recorder, hardware, _) = makeRecorder(keepReady: true)
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }

        recorder.handleLifecycleEvent(.systemWillSleep)
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "invalidate")

        recorder.handleLifecycleEvent(.systemDidWake)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "idle:1")
    }

    func testIdleCaptureFollowsClosedLidTemporarySelectionAndDeviceLoss() async {
        let (recorder, hardware, devices) = makeRecorder(keepReady: true)
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }

        devices.lidClosed = true
        devices.handleClamshellChange(isClosed: true)
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "idle:2")

        devices.selectTemporaryMicrophone(id: 3)
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "idle:3")

        devices.availableDevices = []
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "stopIdle")
    }

    func testIdleCaptureSkipsInputsWithUnmetRequirements() async {
        defaults.audioInputModeRawValue = AudioInputMode.prioritized.rawValue
        let requirement = MicrophoneRequirements(
            application: MicrophoneApplication(bundleID: "com.example.processor", name: "Processor")
        )
        defaults.prioritizedDevicesData = try? JSONEncoder().encode([
            PrioritizedDevice(id: "usb-mic", name: "USB", priority: 0, requirements: requirement)
        ])
        let (recorder, hardware, devices) = makeRecorder(keepReady: true)
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }

        devices.updateRunningApplications(["com.example.processor"])
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)

        XCTAssertEqual(hardware.lastIdleEvent, "idle:2")
    }

    func testPermissionRevocationClosesTheIdleMicrophone() async {
        let (recorder, hardware, _) = makeRecorder(keepReady: true)
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }

        authorized = false
        recorder.handleLifecycleEvent(.applicationDidBecomeActive)
        await settle(recorder)
        XCTAssertEqual(hardware.lastIdleEvent, "stopIdle")
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)

        XCTAssertEqual(hardware.lastIdleEvent, "invalidate")
    }

    func testRecordingUsesTheHeldPressAndIdleCaptureResumesOnlyAfterStop() async throws {
        let (recorder, hardware, _) = makeRecorder(keepReady: true)
        await waitFor(recorder, hardware) { $0.lastIdleEvent == "idle:1" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).wav")

        recorder.holdPreRoll(forPressAt: 42)
        try await recorder.startRecording(toOutputFile: url, applyRecordingEffects: false, preRollPressNanoseconds: 42)
        hardware.clearEvents()
        recorder.handleLifecycleEvent(.audioDeviceChanged)
        await settle(recorder)
        XCTAssertNil(hardware.lastIdleEvent)
        await recorder.stopRecording()
        await settle(recorder)

        XCTAssertTrue(hardware.allEvents.contains("hold:42"))
        XCTAssertTrue(hardware.allEvents.contains("start:1:42"))
        XCTAssertEqual(hardware.events, ["stop", "idle:1"])
    }

    private func makeRecorder(keepReady: Bool = false) -> (Recorder, IdleCaptureHardware, IdleCaptureDevices) {
        defaults.keepMicrophoneReady = keepReady
        let devices = IdleCaptureDevices(userDefaults: defaults)
        let hardware = IdleCaptureHardware()
        let recorder = Recorder(
            hardware: hardware, deviceManager: devices, defaults: defaults,
            isMicrophoneAuthorized: { [unowned self] in self.authorized }
        )
        return (recorder, hardware, devices)
    }

    private func settle(_ recorder: Recorder) async {
        for _ in 0..<5 { await Task.yield() }
        recorder.audioSetupQueue.sync {}
    }

    private func waitFor(
        _ recorder: Recorder, _ hardware: IdleCaptureHardware, file: StaticString = #filePath, line: UInt = #line,
        _ condition: (IdleCaptureHardware) -> Bool
    ) async {
        for _ in 0..<200 {
            await settle(recorder)
            if condition(hardware) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out; events: \(hardware.events)", file: file, line: line)
    }
}

private final class IdleCaptureDevices: AudioDeviceManager {
    var lidClosed = false

    init(userDefaults: UserDefaults) {
        super.init(userDefaults: userDefaults, notificationCenter: NotificationCenter())
    }

    override var isClamshellClosed: Bool { lidClosed }
    override func startMonitoring() {}

    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(1, "internal-mic", "Internal"), (2, "usb-mic", "USB"), (3, "headset-mic", "Headset")]
        completion?()
    }

    override func getSystemDefaultDevice() -> AudioDeviceID? { 1 }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { deviceID == 1 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
}

private final class IdleCaptureHardware: RecordingHardware, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (all: [String](), recent: [String]()))
    var onAudioChunk: ((Data) -> Void)?
    let averagePower: Float = -160
    let peakPower: Float = -160

    var events: [String] { state.withLock { $0.recent } }
    var allEvents: [String] { state.withLock { $0.all } }
    var lastIdleEvent: String? {
        events.last { $0.hasPrefix("idle:") || $0 == "stopIdle" || $0 == "invalidate" }
    }

    func clearEvents() { state.withLock { $0.recent.removeAll() } }

    private func record(_ event: String) {
        state.withLock {
            $0.all.append(event)
            $0.recent.append(event)
        }
    }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        record("start:\(deviceID):none")
    }

    func startRecording(
        toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?,
        preRollPressNanoseconds: UInt64?
    ) throws {
        record("start:\(deviceID):\(preRollPressNanoseconds.map(String.init) ?? "none")")
    }

    func stopRecording() { record("stop") }
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() { record("invalidate") }
    func teardown() {}
    func startIdleCapture(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws { record("idle:\(deviceID)") }
    func stopIdleCapture() { record("stopIdle") }
    func holdPreRoll(forPressAt pressNanoseconds: UInt64) { record("hold:\(pressNanoseconds)") }
}

final class MicrophoneReadinessPersistenceTests: XCTestCase {
    func testSettingRoundTripsThroughConfigurationAndGeneralBackups() throws {
        let suiteName = "MicrophoneReadinessPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.keepMicrophoneReady = true

        XCTAssertEqual(try ConfigurationPreferences.capture(from: defaults)["keepMicrophoneReady"], .bool(true))
        try ConfigurationPreferences.apply(["keepMicrophoneReady": .bool(false)], to: defaults)
        XCTAssertFalse(defaults.keepMicrophoneReady)

        defaults.keepMicrophoneReady = true
        try JSONDecoder().decode(GeneralBackup.self, from: Data("{}".utf8)).restoreMicrophoneReadiness(in: defaults)
        XCTAssertTrue(defaults.keepMicrophoneReady)
        let backup = try JSONDecoder().decode(GeneralBackup.self, from: Data(#"{"keepMicrophoneReady":false}"#.utf8))
        try JSONDecoder().decode(GeneralBackup.self, from: JSONEncoder().encode(backup))
            .restoreMicrophoneReadiness(in: defaults)
        XCTAssertFalse(defaults.keepMicrophoneReady)
    }
}
