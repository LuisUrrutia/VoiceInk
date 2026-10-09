import AVFoundation
import CoreAudio
import SwiftData
import XCTest
import os

@testable import VoiceInk

@MainActor
final class RecordingFinalizationTests: XCTestCase {
    func testStopThenCancelDuringModeResolutionRetainsClosedWAVDuration() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("pending-mode.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        let modeEntered = expectation(description: "mode resolution entered")
        let modeCanceled = expectation(description: "mode resolution canceled")
        let pendingCreated = expectation(forNotification: .transcriptionCreated, object: nil) { _ in true }
        var modeCompletion: CheckedContinuation<Void, Never>?
        let preparation = RecordingTranscriptionPreparation(timing: RecordingTimingTrace())
        preparation.ownModeResolution(Task {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    modeCompletion = continuation
                    modeEntered.fulfill()
                }
            } onCancel: { modeCanceled.fulfill() }
        })
        preparation.start(
            resolveConfiguration: { nil }, retireAutoLearn: {}, prepareModel: { _ in }, prepareSession: { _ in nil }
        )
        engine.activeRecordingPreparation = preparation
        engine.recordedFile = url
        engine.recordingState = .recording
        await fulfillment(of: [modeEntered], timeout: 3)

        let stop = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)
        hardware.releaseStop()
        await fulfillment(of: [pendingCreated], timeout: 3)
        let cancel = Task { await engine.cancelRecording() }
        await fulfillment(of: [modeCanceled], timeout: 3)
        modeCompletion?.resume()
        await cancel.value
        await stop.value

        let entries = try history(in: engine)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.transcriptionStatus, TranscriptionStatus.canceled.rawValue)
        XCTAssertEqual(entries.first?.audioFileURL, url.absoluteString)
        XCTAssertEqual(try XCTUnwrap(entries.first?.duration), 1, accuracy: 0.001)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNil(engine.recordedFile)
    }

    func testCaptureFailureIsRetainedAfterAwaitedStopAndDoesNotEnterTranscription() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("failed.wav")
        let hardware = try HeldRecordingHardware(url: url, captureFailure: RecordingAudioError.conversionFailed)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        engine.recordedFile = url
        engine.recordingState = .recording
        let stop = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)

        hardware.releaseStop()
        await stop.value

        let entries = try history(in: engine)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.transcriptionStatus, TranscriptionStatus.failed.rawValue)
        XCTAssertEqual(entries.first?.text, RecordingAudioError.conversionFailed.localizedDescription)
        XCTAssertNotNil(engine.recorder.recordingError)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertNil(engine.recordedFile)
        XCTAssertNil(engine.recorder.onAudioChunk)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16_000)
    }

    func testStopWaitsForClosedWAVAndFinalStreamingChunk() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let recorder = Recorder(hardware: hardware)
        let chunks = OSAllocatedUnfairLock(initialState: [Data]())
        recorder.onAudioChunk = { data in chunks.withLock { $0.append(data) } }
        var didStop = false

        let stop = Task {
            await recorder.stopRecording()
            didStop = true
        }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)

        XCTAssertFalse(didStop)
        hardware.releaseStop()
        await stop.value

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 16_000)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(chunks.withLock { $0 }, [Data([1, 2])])
        XCTAssertNil(recorder.onAudioChunk)
        XCTAssertNil(hardware.error)
    }

    func testOverlappingStopsWaitForOneHardwareCloseDespiteTaskCancellation() async throws {
        let hardware = try HeldRecordingHardware()
        defer { hardware.releaseStop() }
        let recorder = Recorder(hardware: hardware)
        let secondEntered = expectation(description: "second stop caller")
        var finishedStops = 0
        let first = Task {
            await recorder.stopRecording()
            finishedStops += 1
        }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)

        let second = Task {
            secondEntered.fulfill()
            await recorder.stopRecording()
            finishedStops += 1
        }
        await fulfillment(of: [secondEntered], timeout: 3)
        first.cancel()
        second.cancel()

        XCTAssertEqual(finishedStops, 0)
        hardware.releaseStop()
        await first.value
        await second.value

        XCTAssertEqual(finishedStops, 2)
        XCTAssertEqual(hardware.stopCount, 1)
        XCTAssertNil(hardware.error)
    }

    func testCancelledRestartWaitsForCloseWithoutStartingHardware() async throws {
        let hardware = try HeldRecordingHardware()
        defer { hardware.releaseStop() }
        let recorder = Recorder(hardware: hardware)
        let restartEntered = expectation(description: "restart caller")
        var didRestart = false
        let stop = Task { await recorder.stopRecording() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)

        let restart = Task {
            restartEntered.fulfill()
            defer { didRestart = true }
            try await recorder.startRecording(toOutputFile: URL(fileURLWithPath: "/unused.wav"))
        }
        await fulfillment(of: [restartEntered], timeout: 3)
        restart.cancel()

        XCTAssertFalse(didRestart)
        hardware.releaseStop()
        await stop.value
        do {
            try await restart.value
            XCTFail("A canceled restart must not start capture")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(hardware.startCount, 0)
    }

    func testCancellationDuringStopSavesCompletedOriginalRecording() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        engine.recordedFile = url
        engine.recordingState = .recording
        let stop = Task { await engine.toggleRecord() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)
        let cancelEntered = expectation(description: "cancel caller")

        let cancel = Task {
            cancelEntered.fulfill()
            await engine.cancelRecording()
        }
        await fulfillment(of: [cancelEntered], timeout: 3)

        XCTAssertEqual(engine.recordedFile, url)
        XCTAssertEqual(try history(in: engine).count, 0)
        hardware.releaseStop()
        await stop.value
        await cancel.value

        let entries = try history(in: engine)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.transcriptionStatus, TranscriptionStatus.canceled.rawValue)
        XCTAssertEqual(entries.first?.audioFileURL, url.absoluteString)
        XCTAssertEqual(entries.first?.duration ?? 0, 1, accuracy: 0.001)
        XCTAssertNil(engine.recordedFile)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertEqual(hardware.stopCount, 1)
    }

    func testDuplicateCancellationSavesOneHistoryEntry() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        engine.recordedFile = url
        engine.recordingState = .starting
        let first = Task { await engine.cancelRecording() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)
        let secondEntered = expectation(description: "duplicate cancel caller")

        let second = Task {
            secondEntered.fulfill()
            await engine.cancelRecording()
        }
        await fulfillment(of: [secondEntered], timeout: 3)
        hardware.releaseStop()
        await first.value
        await second.value

        XCTAssertEqual(try history(in: engine).count, 1)
        XCTAssertEqual(hardware.stopCount, 1)
        XCTAssertEqual(engine.recordingState, .idle)
    }

    func testResetWaitsForCancellationToSaveHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        engine.recordedFile = url
        engine.recordingState = .recording
        let cancel = Task { await engine.cancelRecording() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)
        let resetEntered = expectation(description: "reset caller")

        let reset = Task {
            resetEntered.fulfill()
            await engine.resetRecordingSession()
        }
        await fulfillment(of: [resetEntered], timeout: 3)

        XCTAssertEqual(engine.recordedFile, url)
        hardware.releaseStop()
        await cancel.value
        await reset.value

        XCTAssertEqual(try history(in: engine).count, 1)
        XCTAssertNil(engine.recordedFile)
        XCTAssertEqual(engine.recordingState, .idle)
    }

    func testCancelledEngineRestartWaitsForCanceledHistoryCleanup() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recording.wav")
        let hardware = try HeldRecordingHardware(url: url)
        defer { hardware.releaseStop() }
        let engine = try makeEngine(hardware: hardware, directory: directory)
        engine.recordedFile = url
        engine.recordingState = .starting
        let cancel = Task { await engine.cancelRecording() }
        await fulfillment(of: [hardware.stopEntered], timeout: 3)
        let restartEntered = expectation(description: "engine restart caller")
        var didRestart = false

        let restart = Task {
            restartEntered.fulfill()
            await engine.toggleRecord()
            didRestart = true
        }
        await fulfillment(of: [restartEntered], timeout: 3)
        restart.cancel()

        XCTAssertFalse(didRestart)
        XCTAssertEqual(engine.recordedFile, url)
        hardware.releaseStop()
        await cancel.value
        await restart.value

        XCTAssertEqual(try history(in: engine).count, 1)
        XCTAssertNil(engine.recordedFile)
        XCTAssertEqual(engine.recordingState, .idle)
        XCTAssertEqual(hardware.startCount, 0)
    }

    func testStaleCompletionCannotReleaseNextFinalization() async throws {
        let finalization = RecordingFinalization()
        let firstID = try XCTUnwrap(finalization.begin())
        XCTAssertNil(finalization.begin())
        finalization.finish(firstID)
        let secondID = try XCTUnwrap(finalization.begin())

        finalization.finish(firstID)

        XCTAssertTrue(finalization.isRunning)
        finalization.finish(secondID)
        await finalization.waitUntilFinished()
        XCTAssertFalse(finalization.isRunning)
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/recording-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeEngine(hardware: HeldRecordingHardware, directory: URL) throws -> VoiceInkEngine {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Transcription.self, configurations: configuration)
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(
            whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager()
        )
        return VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: Recorder(hardware: hardware)
        )
    }

    private func history(in engine: VoiceInkEngine) throws -> [Transcription] {
        try engine.modelContext.fetch(FetchDescriptor<Transcription>())
    }
}

private final class HeldRecordingHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var callback: ((Data) -> Void)?
        var stopCount = 0
        var startCount = 0
        var error: Error?
    }

    private let state: OSAllocatedUnfairLock<State>
    private let stopGate = DispatchSemaphore(value: 0)
    let stopEntered = XCTestExpectation(description: "hardware stop entered")
    let averagePower: Float = -160
    let peakPower: Float = -160
    let recordingError: Error?

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var startCount: Int { state.withLock { $0.startCount } }
    var error: Error? { state.withLock { $0.error } }

    init(url: URL? = nil, captureFailure: Error? = nil) throws {
        recordingError = captureFailure
        var initial = State()
        if let url {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            initial.file = try AVAudioFile(forWriting: url, settings: format.settings)
            try Self.writeHalfSecond(to: initial.file)
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID) throws {
        state.withLock { $0.startCount += 1 }
    }

    func stopRecording() {
        let isFirstStop = state.withLock { state in
            state.stopCount += 1
            return state.stopCount == 1
        }
        guard isFirstStop else { return }
        stopEntered.fulfill()
        let result = stopGate.wait(timeout: .now() + 10)
        state.withLock { state in
            do {
                if result == .timedOut { throw CocoaError(.userCancelled) }
                try Self.writeHalfSecond(to: state.file)
                state.callback?(Data([1, 2]))
            } catch {
                state.error = error
            }
            state.file = nil
        }
    }

    func releaseStop() { stopGate.signal() }
    func prepare(deviceID: AudioDeviceID) throws {}
    func switchDevice(to deviceID: AudioDeviceID) throws {}
    func invalidatePreparation() {}
    func teardown() {}

    private static func writeHalfSecond(to file: AVAudioFile?) throws {
        guard let file else { return }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_000))
        buffer.frameLength = 8_000
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.update(repeating: 0, count: 8_000)
        try file.write(from: buffer)
    }
}
