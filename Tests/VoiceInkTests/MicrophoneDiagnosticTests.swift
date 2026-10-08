import AVFoundation
import Combine
import CoreAudio
import SwiftData
import XCTest
import os
@testable import VoiceInk

@MainActor
final class MicrophoneDiagnosticTests: XCTestCase {
    func testLocalCaptureWaitsForHardwareStartAndCloseBeforeReportingWAV() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        recorder.holdStart = true
        recorder.holdStop = true
        let diagnostic = makeDiagnostic(recorder, directory: directory)

        XCTAssertTrue(diagnostic.start())
        await fulfillment(of: [recorder.startEntered], timeout: 3)
        XCTAssertEqual(diagnostic.phase, .starting)
        recorder.releaseStart()
        await fulfillment(of: [recorder.stopEntered], timeout: 3)
        XCTAssertEqual(diagnostic.phase, .closing)
        XCTAssertNil(diagnostic.resultURL)
        recorder.releaseStop()
        await waitForCompletion(diagnostic)

        guard case .finished(let report) = diagnostic.phase else { return XCTFail("Expected validated WAV") }
        let file = try AVAudioFile(forReading: XCTUnwrap(diagnostic.resultURL))
        XCTAssertEqual(file.length, 16_000)
        XCTAssertEqual(report.frames, 16_000)
        XCTAssertEqual(report.sampleRate, 16_000)
        XCTAssertEqual(report.channels, 1)
        XCTAssertEqual(recorder.stopCount, 1)
    }

    func testCancelDuringStartupRejectsLateRecordingCallbackAndRemovesAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        recorder.holdStart = true
        let diagnostic = makeDiagnostic(recorder, directory: directory)
        var phases: [MicrophoneDiagnostic.Phase] = []
        let subscription = diagnostic.$phase.sink { phases.append($0) }
        defer { subscription.cancel() }
        diagnostic.start()
        await fulfillment(of: [recorder.startEntered], timeout: 3)

        let cancel = Task { await diagnostic.cancel() }
        await Task.yield()
        XCTAssertFalse(diagnostic.start())
        recorder.releaseStart()
        await cancel.value

        XCTAssertFalse(phases.contains(.recording))
        XCTAssertEqual(diagnostic.phase, .idle)
        XCTAssertNil(diagnostic.resultURL)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancelDuringHardwareCloseKeepsCaptureReservedAndDeletesAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        recorder.holdStop = true
        let diagnostic = makeDiagnostic(recorder, directory: directory)
        diagnostic.start()
        await fulfillment(of: [recorder.stopEntered], timeout: 3)

        let cancel = Task { await diagnostic.cancel() }
        await Task.yield()
        XCTAssertTrue(diagnostic.isBusy)
        XCTAssertFalse(diagnostic.start())
        recorder.releaseStop()
        await cancel.value

        XCTAssertEqual(diagnostic.phase, .idle)
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testStartFailureDoesNotClaimCaptureAndCleansTemporaryWAV() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        recorder.failStart = true
        let diagnostic = makeDiagnostic(recorder, directory: directory)
        var phases: [MicrophoneDiagnostic.Phase] = []
        let subscription = diagnostic.$phase.sink { phases.append($0) }
        defer { subscription.cancel() }

        diagnostic.start()
        await waitForCompletion(diagnostic)

        guard case .failed = diagnostic.phase else { return XCTFail("Expected capture failure") }
        XCTAssertFalse(phases.contains(.recording))
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testStopEarlyValidatesClosedAudioAndReleaseBuildRemovesIt() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        let diagnostic = MicrophoneDiagnostic(
            recorder: recorder, directory: directory, retainAudio: false,
            canStart: { true }, captureIssue: { nil },
            wait: { try await Task.sleep(for: .seconds(60)) }
        )
        diagnostic.start()
        await fulfillment(of: [recorder.startEntered], timeout: 3)

        await diagnostic.stop()

        guard case .finished(let report) = diagnostic.phase else { return XCTFail("Expected early-stop validation") }
        XCTAssertEqual(report.frames, 16_000)
        XCTAssertNil(diagnostic.resultURL)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testInvalidAudioIsRejectedAndRemoved() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        recorder.sampleRate = 48_000
        let diagnostic = makeDiagnostic(recorder, directory: directory)

        diagnostic.start()
        await waitForCompletion(diagnostic)

        guard case .failed = diagnostic.phase else { return XCTFail("Expected format rejection") }
        XCTAssertEqual(recorder.stopCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPermissionAndLiveDictationGatePreventHardwareAccess() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = LocalTestCapture()
        let busy = MicrophoneDiagnostic(
            recorder: recorder, directory: directory, canStart: { false }, captureIssue: { nil }
        )
        let denied = MicrophoneDiagnostic(
            recorder: recorder, directory: directory, canStart: { true },
            captureIssue: { .microphonePermission(.denied) }
        )

        XCTAssertFalse(busy.start())
        XCTAssertFalse(denied.start())
        XCTAssertEqual(recorder.startCount, 0)
    }

    func testDiagnosticUsesConfiguredRecorderAndNeverCreatesHistoryOrTranscription() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "DiagnosticRoutingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let devices = DiagnosticAudioDevices(userDefaults: defaults, notificationCenter: NotificationCenter())
        devices.inputMode = .custom
        devices.selectedDeviceID = 91
        defaults.selectedAudioDeviceUID = "diagnostic-mic"
        let hardware = DiagnosticWAVHardware()
        let recorder = Recorder(hardware: hardware, deviceManager: devices)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let engine = VoiceInkEngine(
            modelContext: container.mainContext, whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: recorder
        )
        let diagnostic = makeDiagnostic(recorder, directory: directory)

        diagnostic.start()
        await waitForCompletion(diagnostic)

        guard case .finished(let report) = diagnostic.phase else { return XCTFail("Expected real Recorder boundary") }
        XCTAssertEqual(hardware.deviceID, 91)
        XCTAssertEqual(report.frames, 16_000)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNil(engine.currentSession)
        XCTAssertNil(engine.recordedFile)
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<Transcription>()).isEmpty)
        XCTAssertNil(hardware.onAudioChunk)
    }

    func testEngineExcludesDictationDuringDiagnosticAndCancellationCreatesNoHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try makeEngine(directory: directory, hardware: DiagnosticWAVHardware())

        XCTAssertTrue(engine.microphoneDiagnostic.start())
        await engine.toggleRecord()
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNil(engine.recordedFile)
        await engine.cancelRecording()

        XCTAssertEqual(engine.microphoneDiagnostic.phase, .idle)
        XCTAssertNil(engine.currentSession)
        XCTAssertTrue(try engine.modelContext.fetch(FetchDescriptor<Transcription>()).isEmpty)
        engine.recordingState = .recording
        XCTAssertFalse(engine.microphoneDiagnostic.start())
        engine.recordingState = .idle
    }

    func testEngineStartFailureReportsErrorWithoutActiveCapture() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let modes = ModeManager.shared
        let originalModes = modes.configurations
        let originalActive = modes.activeConfiguration
        defer { modes.configurations = originalModes; modes.activeConfiguration = originalActive }
        modes.configurations = [ModeConfig(name: "Fixture", isAIEnhancementEnabled: false)]
        modes.activeConfiguration = nil
        let hardware = DiagnosticWAVHardware(failStart: true)
        let engine = try makeEngine(directory: directory, hardware: hardware)
        var states: [RecordingState] = []
        let subscription = engine.$recordingState.sink { states.append($0) }
        defer { subscription.cancel() }

        await engine.toggleRecord()

        XCTAssertTrue(states.contains(.starting))
        XCTAssertFalse(states.contains(.recording))
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNotNil(engine.recordingError)
        XCTAssertNil(engine.recordedFile)
        XCTAssertTrue(try engine.modelContext.fetch(FetchDescriptor<Transcription>()).isEmpty)
    }

    private func makeEngine(directory: URL, hardware: DiagnosticWAVHardware) throws -> VoiceInkEngine {
        let devices = DiagnosticAudioDevices(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let recorder = Recorder(hardware: hardware, deviceManager: devices)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let readiness = CaptureReadinessController(models: models, devices: devices, permissionReader: { (.granted, false) })
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: recorder, captureReadiness: readiness
        )
    }

    private func makeDiagnostic(_ recorder: any MicrophoneCapturing, directory: URL) -> MicrophoneDiagnostic {
        MicrophoneDiagnostic(
            recorder: recorder, directory: directory, retainAudio: true,
            canStart: { true }, captureIssue: { nil }, wait: {}
        )
    }

    private func waitForCompletion(_ diagnostic: MicrophoneDiagnostic) async {
        let completion = expectation(description: "diagnostic finished")
        let subscription = diagnostic.$phase.dropFirst().sink { phase in
            if !phase.isBusy { completion.fulfill() }
        }
        defer { subscription.cancel() }
        if !diagnostic.isBusy { return }
        await fulfillment(of: [completion], timeout: 5)
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/capture-readiness-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

@MainActor
private final class LocalTestCapture: MicrophoneCapturing {
    var holdStart = false
    var holdStop = false
    var failStart = false
    var sampleRate = 16_000.0
    var startCount = 0
    var stopCount = 0
    private var file: AVAudioFile?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var stopContinuation: CheckedContinuation<Void, Never>?
    let startEntered = XCTestExpectation(description: "capture start entered")
    let stopEntered = XCTestExpectation(description: "capture stop entered")

    func startMicrophoneTest(toOutputFile url: URL) async throws {
        startCount += 1
        file = try makeAudioFile(url, sampleRate: sampleRate)
        startEntered.fulfill()
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if failStart { throw Recorder.RecorderError.couldNotStartRecording }
    }

    func stopRecording() async {
        stopCount += 1
        stopEntered.fulfill()
        if holdStop { await withCheckedContinuation { stopContinuation = $0 } }
        if let file { try? writeFinalFrames(file) }
        file = nil
    }

    func audioMeterSnapshot() -> AudioMeter { AudioMeter(averagePower: 0, peakPower: 0) }
    func releaseStart() { startContinuation?.resume(); startContinuation = nil }
    func releaseStop() { stopContinuation?.resume(); stopContinuation = nil }
}

private final class DiagnosticAudioDevices: AudioDeviceManager {
    override func startMonitoring() {}
    override func loadAvailableDevices(completion: (() -> Void)? = nil) {
        availableDevices = [(id: 91, uid: "diagnostic-mic", name: "Diagnostic microphone")]
        completion?()
    }
    override func getSystemDefaultDevice() -> AudioDeviceID? { 91 }
    override func getDeviceModelUID(deviceID: AudioDeviceID) -> String? { nil }
    override func isInternalMicrophone(_ deviceID: AudioDeviceID) -> Bool { false }
}

private final class DiagnosticWAVHardware: RecordingHardware, @unchecked Sendable {
    private let failStart: Bool
    private struct State {
        var file: AVAudioFile?
        var deviceID: AudioDeviceID?
        var callback: ((Data) -> Void)?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    init(failStart: Bool = false) { self.failStart = failStart }
    var deviceID: AudioDeviceID? { state.withLock { $0.deviceID } }
    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var averagePower: Float { -60 }
    var peakPower: Float { -60 }
    func prepare(deviceID: AudioDeviceID) throws {}
    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        if failStart { throw Recorder.RecorderError.couldNotStartRecording }
        let file = try makeAudioFile(url, sampleRate: 16_000)
        state.withLock { $0.file = file; $0.deviceID = deviceID }
    }
    func stopRecording() {
        state.withLock { state in
            if let file = state.file { try? writeFinalFrames(file) }
            state.file = nil
        }
    }
    func switchDevice(to deviceID: AudioDeviceID) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}

private func makeAudioFile(_ url: URL, sampleRate: Double) throws -> AVAudioFile {
    try AVAudioFile(forWriting: url, settings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
}

private func writeFinalFrames(_ file: AVAudioFile) throws {
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_000)!
    buffer.frameLength = 16_000
    buffer.floatChannelData![0].initialize(repeating: 0, count: 16_000)
    try file.write(from: buffer)
}
