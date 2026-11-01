import AVFoundation
import Combine
import CoreAudio
import SwiftData
import XCTest
import os

@testable import VoiceInk

@MainActor
final class DictationJobLifecycleTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        directory = root.appendingPathComponent(".tmp/dictation-job-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStopHandsTheCaptureToOneJobWithoutAnIdleGap() async throws {
        let fixture = try makeFixture()
        var states: [RecordingState] = []
        let subscription = fixture.engine.$recordingState.sink { states.append($0) }
        defer { subscription.cancel() }
        try fixture.fabricateCapture()
        let capture = try XCTUnwrap(fixture.engine.capture)
        XCTAssertEqual(fixture.engine.recordingState, capture.phase)

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)

        let job = try XCTUnwrap(fixture.engine.job)
        XCTAssertNil(fixture.engine.capture)
        XCTAssertTrue(job.preparation === fixture.preparation)
        XCTAssertTrue(job.delivery === fixture.delivery)
        XCTAssertEqual(job.audioURL, fixture.url)
        XCTAssertEqual(fixture.engine.recordedFile, fixture.url)
        XCTAssertEqual(job.sequence, 1)
        XCTAssertNil(job.transcriptionID)
        XCTAssertNil(job.task)
        XCTAssertEqual(fixture.engine.recordingState, .transcribing)
        XCTAssertEqual(fixture.engine.recordingState, job.phase)

        fixture.hardware.releaseStop()
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)

        let pending = try XCTUnwrap(try history(in: fixture.engine).first)
        XCTAssertEqual(job.transcriptionID, pending.id)
        XCTAssertNotNil(job.task)
        XCTAssertTrue(fixture.engine.job === job)
        XCTAssertFalse(job.outputStarted)
        await fixture.engine.cancelRecording()
        await stop.value

        XCTAssertEqual(states, [.idle, .recording, .transcribing, .idle])
        XCTAssertNil(fixture.engine.job)
        XCTAssertNil(fixture.engine.recordedFile)
        XCTAssertTrue(fixture.delivery.isCancelled)
        XCTAssertEqual(try history(in: fixture.engine).map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
    }

    func testCancelingTheStopCallerCancelsTheJobTask() async throws {
        let fixture = try makeFixture()
        try fixture.fabricateCapture()
        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        fixture.hardware.releaseStop()
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)
        let jobTask = try XCTUnwrap(job.task)
        let stopReturned = expectation(description: "stop caller returned")

        stop.cancel()
        Task {
            await stop.value
            stopReturned.fulfill()
        }
        await fulfillment(of: [stopReturned], timeout: 3)

        XCTAssertTrue(jobTask.isCancelled)
        XCTAssertNil(fixture.engine.job)
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertEqual(try history(in: fixture.engine).map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
    }

    func testCancelDuringTheHardwareStopEndsTheJobWithoutAPipeline() async throws {
        let fixture = try makeFixture()
        try fixture.fabricateCapture()

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)
        let cancel = Task { await fixture.engine.cancelRecording() }
        try await waitUntil { job.cancelRequested }
        fixture.hardware.releaseStop()
        await stop.value
        await cancel.value

        XCTAssertNil(job.task)
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertNil(fixture.engine.job)
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        let entries = try history(in: fixture.engine)
        XCTAssertEqual(entries.map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
        XCTAssertEqual(try XCTUnwrap(entries.first?.duration), 1, accuracy: 0.001)
    }

    func testCancelWhileTheJobResolvesItsModeSavesOneCanceledRow() async throws {
        let modeGate = ModeResolutionGate()
        let fixture = try makeFixture(modeGate: modeGate)
        let transcriptionCreated = expectation(forNotification: .transcriptionCreated, object: nil) { _ in true }
        try fixture.fabricateCapture()

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        fixture.hardware.releaseStop()
        await fulfillment(of: [transcriptionCreated, modeGate.entered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)
        let cancel = Task { await fixture.engine.cancelRecording() }
        try await waitUntil { job.cancelRequested }
        modeGate.resume()
        await cancel.value
        await stop.value

        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertNil(fixture.engine.job)
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertEqual(try history(in: fixture.engine).map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
    }

    func testCancelDuringEnhancementCancelsTheJobAndReturnsToIdle() async throws {
        let fixture = try makeFixture()
        try fixture.fabricateCapture()

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        fixture.hardware.releaseStop()
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)
        fixture.engine.recordingState = .enhancing
        XCTAssertEqual(job.phase, .enhancing)
        XCTAssertNil(fixture.engine.capture)

        await fixture.engine.cancelRecording()
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertTrue(job.cancelRequested)
        await stop.value

        XCTAssertNil(fixture.engine.job)
        XCTAssertEqual(try history(in: fixture.engine).map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
    }

    func testStartWhileAJobTranscribesIsIgnored() async throws {
        let fixture = try makeFixture()
        try fixture.fabricateCapture()
        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        fixture.hardware.releaseStop()
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)

        await fixture.engine.toggleRecord()

        XCTAssertEqual(fixture.hardware.startCount, 0)
        XCTAssertTrue(fixture.engine.job === job)
        XCTAssertNil(fixture.engine.capture)
        XCTAssertFalse(fixture.delivery.isCancelled)
        XCTAssertFalse(job.cancelRequested)
        XCTAssertEqual(fixture.engine.recordingState, .transcribing)
        await fixture.engine.cancelRecording()
        await stop.value
        XCTAssertEqual(try history(in: fixture.engine).count, 1)
    }

    func testStartAfterCancelSupersedesTheJobThatIsStillWindingDown() async throws {
        let detector = HeldSpeechDetector()
        let fixture = try makeFixture(detector: detector)
        try fixture.fabricateCapture()
        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.hardware.stopEntered], timeout: 3)
        fixture.hardware.releaseStop()
        await fulfillment(of: [detector.entered], timeout: 3)
        let job = try XCTUnwrap(fixture.engine.job)
        await fixture.engine.cancelRecording()
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertTrue(fixture.engine.job === job)

        // Denied microphone access fails the new start's preflight after it supersedes the job.
        await fixture.engine.toggleRecord(
            deliverySession: RecordingDeliverySession(destination: .currentApplication, playFeedback: { _ in })
        )

        XCTAssertNil(fixture.engine.job)
        XCTAssertNil(fixture.engine.capture)
        XCTAssertTrue(fixture.delivery.isCancelled)
        XCTAssertEqual(fixture.hardware.startCount, 0)
        detector.release()
        await stop.value
        XCTAssertNil(fixture.engine.job)
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertEqual(try history(in: fixture.engine).map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
    }

    // MARK: - Fixtures

    @MainActor
    private final class Fixture {
        let engine: VoiceInkEngine
        let hardware: HeldStopHardware
        let session: BlockingSession
        let url: URL
        let modeGate: ModeResolutionGate?
        private(set) var preparation: RecordingTranscriptionPreparation!
        private(set) var delivery: RecordingDeliverySession!

        init(
            engine: VoiceInkEngine, hardware: HeldStopHardware, session: BlockingSession, url: URL,
            modeGate: ModeResolutionGate?
        ) {
            self.engine = engine
            self.hardware = hardware
            self.session = session
            self.url = url
            self.modeGate = modeGate
        }

        func fabricateCapture() throws {
            let timing = RecordingTimingTrace(originNanoseconds: DispatchTime.now().uptimeNanoseconds - 1_000_000_000)
            timing.mark(.firstAudio, at: timing.originNanoseconds)
            let preparation = RecordingTranscriptionPreparation(timing: timing)
            if let modeGate {
                preparation.ownModeResolution(Task { await modeGate.wait() })
            }
            let configuration = TranscriptionRuntimeConfiguration(
                mode: ModeConfig(name: "Job fixture", isAIEnhancementEnabled: false),
                model: ImportedWhisperModel(fileBaseName: "ggml-small"), languages: ["en"], isRealtimeEnabled: true
            )
            let session = self.session
            preparation.start(
                resolveConfiguration: { _ in configuration }, retireAutoLearn: {}, prepareModel: { _ in },
                prepareSession: { _ in session }
            )
            let delivery = RecordingDeliverySession(destination: .currentApplication, timing: timing, playFeedback: { _ in })
            self.preparation = preparation
            self.delivery = delivery
            engine.activeRecordingPreparation = preparation
            engine.activeRecordingDelivery = delivery
            engine.recordedFile = url
            engine.recordingState = .recording
        }
    }

    private func makeFixture(
        modeGate: ModeResolutionGate? = nil, detector: HeldSpeechDetector? = nil
    ) throws -> Fixture {
        let url = directory.appendingPathComponent("job.wav")
        let hardware = try HeldStopHardware(url: url)
        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, VocabularySection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager())
        let recorder = Recorder(hardware: hardware, deviceManager: FixedInputAudioDevices())
        let readiness = CaptureReadinessController(
            models: models, devices: recorder.deviceManager, permissionReader: { (.denied, false) }
        )
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: recorder, captureReadiness: readiness,
            speechDetector: detector, isNoSpeechGateEnabled: { detector != nil }, startSoundPlayback: { nil }
        )
        return Fixture(
            engine: engine, hardware: hardware, session: BlockingSession(), url: url, modeGate: modeGate
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Condition not reached") }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func history(in engine: VoiceInkEngine) throws -> [Transcription] {
        try engine.modelContext.fetch(FetchDescriptor<Transcription>())
    }
}

@MainActor
private final class ModeResolutionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    let entered = XCTestExpectation(description: "mode resolution entered")

    func wait() async -> UUID? {
        entered.fulfill()
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
        return nil
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HeldSpeechDetector: SpeechDetecting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    let entered = XCTestExpectation(description: "speech detector entered")

    func containsSpeech(in samples: [Float]) async throws -> Bool? {
        entered.fulfill()
        if !isReleased { await withCheckedContinuation { continuation = $0 } }
        return false
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

/// A streaming session whose transcription waits until it or its task is canceled.
@MainActor
private final class BlockingSession: TranscriptionSession {
    private(set) var transcribeCount = 0
    private var cancelCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    let transcribeEntered = XCTestExpectation(description: "transcription entered")

    func prepare(
        configuration: TranscriptionRuntimeConfiguration, vocabulary: RecordingVocabulary
    ) async throws -> ((Data) -> Void)? {
        { _ in }
    }

    func transcribe(audioURL: URL, vocabulary: RecordingVocabulary) async throws -> String {
        transcribeCount += 1
        transcribeEntered.fulfill()
        if cancelCount == 0 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { @MainActor in self.cancel() }
            }
        }
        throw CancellationError()
    }

    func cancel() {
        cancelCount += 1
        continuation?.resume()
        continuation = nil
    }
}

/// Writes one second of audible tone to the WAV when its held stop is released.
private final class HeldStopHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var url: URL?
        var callback: ((Data) -> Void)?
        var startCount = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stopGate = DispatchSemaphore(value: 0)
    let stopEntered = XCTestExpectation(description: "hardware stop entered")
    let averagePower: Float = -160
    let peakPower: Float = -160
    let recordingError: Error? = nil

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var startCount: Int { state.withLock { $0.startCount } }

    init(url: URL) throws {
        state = OSAllocatedUnfairLock(initialState: State(url: url))
    }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        state.withLock { $0.startCount += 1 }
    }

    func stopRecording() {
        guard let url = state.withLock({ state -> URL? in defer { state.url = nil }; return state.url }) else { return }
        stopEntered.fulfill()
        _ = stopGate.wait(timeout: .now() + 10)
        try? Self.writeTone(to: url)
    }

    func releaseStop() { stopGate.signal() }
    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}

    private static func writeTone(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { samples[index] = 0.2 * Float(sin(2 * Double.pi * 440 * Double(index) / 16_000)) }
        try file.write(from: buffer)
    }
}
