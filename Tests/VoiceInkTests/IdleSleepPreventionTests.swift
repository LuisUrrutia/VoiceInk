import AVFoundation
import CoreAudio
import IOKit.pwr_mgt
import SwiftData
import XCTest
import os

@testable import VoiceInk

final class IdleSleepPreventionTests: XCTestCase {
    func testHoldAcquiresOnceAndReleasesOnce() {
        let (client, prevention, queue) = makePrevention()

        let hold = prevention.begin()
        queue.sync {}
        XCTAssertEqual(client.liveAssertions.count, 1)
        hold.release()
        hold.release()
        queue.sync {}

        XCTAssertEqual(client.createdNames, [IdleSleepPrevention.dictationAssertionName])
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
    }

    func testFailedAcquisitionIsNotReleased() {
        let (client, prevention, queue) = makePrevention(failure: kIOReturnNotPermitted)

        let hold = prevention.begin()
        hold.release()
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertTrue(client.releasedIDs.isEmpty)
    }

    func testReleaseBeforeAcquisitionCompletesStillReleasesIt() {
        let (client, prevention, queue) = makePrevention()
        queue.suspend()

        let hold = prevention.begin()
        hold.release()
        queue.resume()
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
    }

    func testReleasingOneHoldLeavesNewerHoldActive() {
        let (client, prevention, queue) = makePrevention()
        let old = prevention.begin()
        queue.sync {}
        let oldID = client.liveAssertions.first
        let newer = prevention.begin()
        queue.sync {}

        old.release()
        old.release()
        queue.sync {}

        XCTAssertEqual(client.releasedIDs, oldID.map { [$0] })
        XCTAssertEqual(client.liveAssertions.count, 1)
        newer.release()
        queue.sync {}
        XCTAssertTrue(client.liveAssertions.isEmpty)
    }

    func testReleaseAllReleasesOutstandingHoldsAndRefusesLaterOnes() {
        let (client, prevention, queue) = makePrevention()
        let first = prevention.begin()
        let second = prevention.begin()

        prevention.releaseAll()
        let late = prevention.begin()
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 2)
        XCTAssertEqual(client.releasedIDs.count, 2)
        XCTAssertTrue(client.liveAssertions.isEmpty)
        first.release()
        second.release()
        late.release()
        queue.sync {}
        XCTAssertEqual(client.releasedIDs.count, 2)
    }

    func testDroppedHoldReleasesItsAssertion() {
        let (client, prevention, queue) = makePrevention()

        _ = prevention.begin()
        queue.sync {}

        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
    }

    @MainActor
    func testDeliverySessionReleasesOnCancelAndRejectsLaterHolds() {
        let (client, prevention, queue) = makePrevention()
        let session = RecordingDeliverySession(destination: .currentApplication)
        session.preventIdleSleep(prevention.begin())
        queue.sync {}
        XCTAssertEqual(client.liveAssertions.count, 1)

        session.cancel()
        session.cancel()
        session.preventIdleSleep(prevention.begin())
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 2)
        XCTAssertEqual(client.releasedIDs.count, 2)
        XCTAssertTrue(client.liveAssertions.isEmpty)
    }

    /// Opt-in: `TEST_RUNNER_VOICEINK_POWER_ASSERTION_SMOKE=1` holds a real assertion without microphone capture.
    func testNativeAssertionAppearsInPmsetAndClearsAfterRelease() throws {
        guard ProcessInfo.processInfo.environment["VOICEINK_POWER_ASSERTION_SMOKE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_VOICEINK_POWER_ASSERTION_SMOKE=1 to check the native assertion with pmset")
        }
        let queue = DispatchQueue(label: "IdleSleepPreventionTests.native")
        let prevention = IdleSleepPrevention(queue: queue)
        let name = "VoiceInk smoke \(UUID().uuidString)"

        let hold = prevention.begin(name: name)
        queue.sync {}
        let held = try assertionLines(named: name)
        hold.release()
        queue.sync {}
        let released = try assertionLines(named: name)

        XCTAssertEqual(held.count, 1, "pmset did not list the assertion")
        XCTAssertTrue(held.first?.contains("pid \(getpid())(") == true, held.first ?? "")
        XCTAssertTrue(held.first?.contains("PreventUserIdleSystemSleep") == true, held.first ?? "")
        XCTAssertTrue(released.isEmpty, released.joined(separator: "\n"))
    }

    private func assertionLines(named name: String) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.contains("\"\(name)\"") }
    }
}

@MainActor
final class RecordingIdleSleepTests: XCTestCase {
    private var originalModes: [ModeConfig] = []
    private var originalActiveMode: ModeConfig?
    private var directory: URL!

    override func setUp() async throws {
        let modes = ModeManager.shared
        originalModes = modes.configurations
        originalActiveMode = modes.activeConfiguration
        modes.configurations = [ModeConfig(name: "Idle Sleep Fixture", isAIEnhancementEnabled: false)]
        modes.activeConfiguration = nil
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".tmp/idle-sleep-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ModeManager.shared.configurations = originalModes
        ModeManager.shared.activeConfiguration = originalActiveMode
        try? FileManager.default.removeItem(at: directory)
    }

    func testIntentionalRecordingHoldsAssertionUntilItsFailedSetupEnds() async throws {
        let (client, prevention, queue) = makePrevention()
        let hardware = SleepTestHardware()
        var liveAtCapture: Int?
        hardware.onStart = {
            queue.sync {}
            liveAtCapture = client.liveAssertions.count
        }
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)

        await engine.toggleRecord()
        queue.sync {}

        XCTAssertEqual(hardware.startCount, 1)
        XCTAssertEqual(liveAtCapture, 1)
        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNil(engine.activeRecordingDelivery)
        withExtendedLifetime(panel) {}
    }

    func testFailedAcquisitionStillStartsRecording() async throws {
        let (client, prevention, queue) = makePrevention(failure: kIOReturnNotPermitted)
        let hardware = SleepTestHardware()
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)

        await engine.toggleRecord()
        queue.sync {}

        XCTAssertEqual(hardware.startCount, 1)
        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertTrue(client.releasedIDs.isEmpty)
        withExtendedLifetime(panel) {}
    }

    func testHardwareStartFailureReleasesAssertion() async throws {
        let (client, prevention, queue) = makePrevention()
        let hardware = SleepTestHardware()
        hardware.failStart = true
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)

        await engine.toggleRecord()
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertNil(engine.activeRecordingDelivery)
        withExtendedLifetime(panel) {}
    }

    func testHardwareStartFailurePlaysItsErrorToneBeforeEndingTheSession() async throws {
        let (_, prevention, _) = makePrevention()
        let hardware = SleepTestHardware()
        hardware.failStart = true
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)
        var tones: [DictationFeedback.Tone] = []
        let session = RecordingDeliverySession(destination: .currentApplication, playFeedback: { tones.append($0) })

        await engine.toggleRecord(deliverySession: session)

        XCTAssertEqual(tones, [.error])
        XCTAssertTrue(session.isCancelled)
        withExtendedLifetime(panel) {}
    }

    func testPreflightFailurePlaysTheErrorToneWithoutStartingCapture() async throws {
        let (client, prevention, _) = makePrevention()
        let hardware = SleepTestHardware()
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)
        ModeManager.shared.configurations = []
        var tones: [DictationFeedback.Tone] = []
        let session = RecordingDeliverySession(destination: .currentApplication, playFeedback: { tones.append($0) })

        await engine.toggleRecord(deliverySession: session)

        XCTAssertEqual(tones, [.error])
        XCTAssertEqual(hardware.startCount, 0)
        XCTAssertTrue(client.createdNames.isEmpty)
        withExtendedLifetime(panel) {}
    }

    func testCancelDuringStartupReleasesAssertionBeforeCaptureFinishesStarting() async throws {
        let (client, prevention, queue) = makePrevention()
        let hardware = SleepTestHardware()
        hardware.holdStart = true
        defer { hardware.releaseStart() }
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)
        let start = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.startEntered], timeout: 5)
        queue.sync {}
        XCTAssertEqual(client.liveAssertions.count, 1)

        let cancel = Task { await engine.cancelRecording() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !engine.shouldCancelRecording, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(engine.shouldCancelRecording)
        queue.sync {}
        XCTAssertEqual(client.releasedIDs.count, 1)
        hardware.releaseStart()
        await cancel.value
        await start.value
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
        XCTAssertEqual(engine.recordingState, .idle)
        withExtendedLifetime(panel) {}
    }

    func testStoppedRecordingKeepsAssertionUntilPipelineCompletes() async throws {
        let (client, prevention, queue) = makePrevention()
        let hardware = SleepTestHardware()
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)
        let pending = try enterPipeline(engine, hardware: hardware, prevention: prevention)
        let stop = Task { await engine.toggleRecord() }
        await fulfillment(of: [pending.transcriptionCreated, pending.modeEntered], timeout: 5)
        queue.sync {}
        XCTAssertEqual(engine.recordingState, .transcribing)
        XCTAssertEqual(client.liveAssertions.count, 1)

        pending.completeModeResolution()
        await stop.value
        queue.sync {}

        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertEqual(client.createdNames.count, 1)
        XCTAssertEqual(client.releasedIDs.count, 1)
        XCTAssertTrue(client.liveAssertions.isEmpty)
        withExtendedLifetime(panel) {}
    }

    func testCanceledPipelineDoesNotReleaseNewerRecordingAssertion() async throws {
        let (client, prevention, queue) = makePrevention()
        let hardware = SleepTestHardware()
        let (engine, panel) = try makeEngine(hardware: hardware, prevention: prevention)
        let pending = try enterPipeline(engine, hardware: hardware, prevention: prevention)
        let stop = Task { await engine.toggleRecord() }
        await fulfillment(of: [pending.transcriptionCreated, pending.modeEntered], timeout: 5)
        queue.sync {}
        let oldID = try XCTUnwrap(client.liveAssertions.first)

        let cancel = Task { await engine.cancelRecording() }
        await fulfillment(of: [pending.modeCanceled], timeout: 5)
        queue.sync {}
        XCTAssertEqual(client.releasedIDs, [oldID])
        pending.completeModeResolution()
        await cancel.value
        hardware.holdStart = true
        defer { hardware.releaseStart() }
        let restart = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.startEntered], timeout: 5)
        await stop.value
        queue.sync {}

        XCTAssertEqual(client.createdNames.count, 2)
        XCTAssertEqual(client.releasedIDs, [oldID])
        XCTAssertEqual(client.liveAssertions.count, 1)
        hardware.releaseStart()
        await restart.value
        queue.sync {}
        XCTAssertEqual(client.releasedIDs.count, 2)
        XCTAssertTrue(client.liveAssertions.isEmpty)
        withExtendedLifetime(panel) {}
    }

    private struct PendingPipeline {
        let transcriptionCreated: XCTestExpectation
        let modeEntered: XCTestExpectation
        let modeCanceled: XCTestExpectation
        let completeModeResolution: () -> Void
    }

    /// Reproduces a recording whose Stop waits on pending mode resolution inside the pipeline.
    private func enterPipeline(
        _ engine: VoiceInkEngine, hardware: SleepTestHardware, prevention: IdleSleepPrevention
    ) throws -> PendingPipeline {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        try hardware.open(url)
        let modeEntered = expectation(description: "mode resolution entered")
        let modeCanceled = XCTestExpectation(description: "mode resolution canceled")
        let gate = ModeResolutionGate()
        let preparation = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        preparation.ownModeResolution(Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    gate.store(continuation)
                    modeEntered.fulfill()
                }
            } onCancel: { modeCanceled.fulfill() }
        })
        preparation.start(
            resolveConfiguration: { nil }, retireAutoLearn: {}, prepareModel: { _ in }, prepareSession: { _ in nil }
        )
        let delivery = RecordingDeliverySession(destination: .currentApplication)
        delivery.preventIdleSleep(prevention.begin())
        engine.activeRecordingPreparation = preparation
        engine.activeRecordingDelivery = delivery
        engine.recordedFile = url
        engine.recordingState = .recording
        return PendingPipeline(
            transcriptionCreated: expectation(forNotification: .transcriptionCreated, object: nil) { _ in true },
            modeEntered: modeEntered,
            modeCanceled: modeCanceled,
            completeModeResolution: gate.resume
        )
    }

    private func makeEngine(
        hardware: SleepTestHardware, prevention: IdleSleepPrevention
    ) throws -> (VoiceInkEngine, VisibleRecorderPanel) {
        let devices = SleepTestAudioDevices(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let readiness = CaptureReadinessController(models: models, devices: devices, permissionReader: { (.granted, false) })
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: Recorder(hardware: hardware, deviceManager: devices),
            captureReadiness: readiness, idleSleepPrevention: prevention
        )
        let panel = VisibleRecorderPanel()
        engine.recorderUIManager = panel
        return (engine, panel)
    }
}

private func makePrevention(
    failure: IOReturn? = nil
) -> (FakePowerAssertionClient, IdleSleepPrevention, DispatchQueue) {
    let client = FakePowerAssertionClient(failure: failure)
    let queue = DispatchQueue(label: "IdleSleepPreventionTests.\(UUID().uuidString)")
    return (client, IdleSleepPrevention(client: client, queue: queue), queue)
}

private final class FakePowerAssertionClient: PowerAssertionClient, @unchecked Sendable {
    private struct State {
        var nextID: IOPMAssertionID = 100
        var createdNames: [String] = []
        var releasedIDs: [IOPMAssertionID] = []
        var live: [IOPMAssertionID] = []
    }

    private let failure: IOReturn?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(failure: IOReturn?) {
        self.failure = failure
    }

    var createdNames: [String] { state.withLock { $0.createdNames } }
    var releasedIDs: [IOPMAssertionID] { state.withLock { $0.releasedIDs } }
    var liveAssertions: [IOPMAssertionID] { state.withLock { $0.live } }

    func createIdleSleepAssertion(named name: String) -> Result<IOPMAssertionID, IdleSleepPreventionError> {
        state.withLock { state in
            state.createdNames.append(name)
            if let failure { return .failure(IdleSleepPreventionError(status: failure)) }
            state.nextID += 1
            state.live.append(state.nextID)
            return .success(state.nextID)
        }
    }

    func releaseAssertion(_ id: IOPMAssertionID) -> IOReturn {
        state.withLock { state in
            state.releasedIDs.append(id)
            guard let index = state.live.firstIndex(of: id) else { return kIOReturnNotFound }
            state.live.remove(at: index)
            return kIOReturnSuccess
        }
    }
}

private final class ModeResolutionGate: @unchecked Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    func store(_ value: CheckedContinuation<Void, Never>) {
        continuation.withLock { $0 = value }
    }

    func resume() {
        continuation.withLock { value in
            value?.resume()
            value = nil
        }
    }
}

@MainActor
private final class VisibleRecorderPanel: RecorderPanelPresenting {
    var isRecorderPanelVisible = true
    func dismissRecorderPanel() async {}
}

private final class SleepTestAudioDevices: AudioDeviceManager {
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 92, uid: "idle-sleep-mic", name: "Idle sleep microphone")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { 92 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
}

private final class SleepTestHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var callback: ((Data) -> Void)?
        var startCount = 0
        var holdStart = false
        var failStart = false
        var onStart: (() -> Void)?
        var startEntered = XCTestExpectation(description: "hardware start entered")
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let startGate = DispatchSemaphore(value: 0)
    let averagePower: Float = -60
    let peakPower: Float = -60
    let recordingError: Error? = nil

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var startCount: Int { state.withLock { $0.startCount } }
    var startEntered: XCTestExpectation { state.withLock { $0.startEntered } }
    var holdStart: Bool {
        get { state.withLock { $0.holdStart } }
        set {
            state.withLock {
                $0.holdStart = newValue
                if newValue { $0.startEntered = XCTestExpectation(description: "hardware start entered") }
            }
        }
    }
    var failStart: Bool {
        get { state.withLock { $0.failStart } }
        set { state.withLock { $0.failStart = newValue } }
    }
    var onStart: (() -> Void)? {
        get { state.withLock { $0.onStart } }
        set { state.withLock { $0.onStart = newValue } }
    }

    func open(_ url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        state.withLock { $0.file = file }
    }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        let (hold, fail, onStart, entered) = state.withLock { state in
            state.startCount += 1
            return (state.holdStart, state.failStart, state.onStart, state.startEntered)
        }
        onStart?()
        entered.fulfill()
        if hold { _ = startGate.wait(timeout: .now() + 10) }
        if fail { throw Recorder.RecorderError.couldNotStartRecording }
        try open(url)
    }

    func stopRecording() {
        state.withLock { state in
            if let file = state.file,
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)
            {
                buffer.frameLength = 16_000
                buffer.floatChannelData?[0].update(repeating: 0, count: 16_000)
                try? file.write(from: buffer)
            }
            state.file = nil
        }
    }

    func releaseStart() {
        let isHeld = state.withLock { state in
            defer { state.holdStart = false }
            return state.holdStart
        }
        if isHeld { startGate.signal() }
    }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
