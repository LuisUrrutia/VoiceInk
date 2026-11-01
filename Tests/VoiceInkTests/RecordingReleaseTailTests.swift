import AVFoundation
import CoreAudio
import SwiftData
import XCTest
import os

@testable import VoiceInk

@MainActor
final class RecordingReleaseTailTests: XCTestCase {
    private let millisecond: UInt64 = 1_000_000

    // MARK: - Tail bounds on a fake monotonic clock

    func testTailWaitsUntilAudioThroughReleasePlusTailArrives() async {
        let tail = RecordingReleaseTail(releasedAtNanoseconds: 1_000 * millisecond)
        let clock = FakeClock(now: tail.releasedAtNanoseconds)
        // Hardware delivers audio 10 ms behind the clock.
        let outcome = await tail.waitForCapture(
            capturedThrough: { clock.now - 10 * self.millisecond },
            shouldEndEarly: { false }, now: { clock.now }, sleep: { clock.now += $0 }
        )

        XCTAssertEqual(outcome.reason, .captured)
        XCTAssertGreaterThanOrEqual(outcome.endedAtNanoseconds, tail.releasedAtNanoseconds + 210 * millisecond)
        XCTAssertLessThan(outcome.endedAtNanoseconds, tail.waitDeadlineNanoseconds)
    }

    func testStalledStreamFinishesAtTailPlusGraceWithWhatArrived() async {
        let tail = RecordingReleaseTail(releasedAtNanoseconds: 1_000 * millisecond)
        let clock = FakeClock(now: tail.releasedAtNanoseconds)
        let frozen = tail.releasedAtNanoseconds + 50 * millisecond

        let outcome = await tail.waitForCapture(
            capturedThrough: { frozen }, shouldEndEarly: { false },
            now: { clock.now }, sleep: { clock.now += $0 }
        )

        XCTAssertEqual(outcome.reason, .stalled)
        XCTAssertEqual(outcome.endedAtNanoseconds, tail.releasedAtNanoseconds + 300 * millisecond)
    }

    func testFailedStreamWithoutAudioIsBoundedAndCancellationEndsTheTail() async {
        let tail = RecordingReleaseTail(releasedAtNanoseconds: 1_000 * millisecond)
        let clock = FakeClock(now: tail.releasedAtNanoseconds)
        let failed = await tail.waitForCapture(
            capturedThrough: { nil }, shouldEndEarly: { false }, now: { clock.now }, sleep: { clock.now += $0 }
        )
        XCTAssertEqual(failed, .init(reason: .stalled, endedAtNanoseconds: tail.waitDeadlineNanoseconds))

        clock.now = tail.releasedAtNanoseconds
        var canceled = false
        let ended = await tail.waitForCapture(
            capturedThrough: { nil }, shouldEndEarly: { canceled }, now: { clock.now },
            sleep: { clock.now += $0; if clock.now >= tail.releasedAtNanoseconds + 40 * self.millisecond { canceled = true } }
        )
        XCTAssertEqual(ended.reason, .endedEarly)
        XCTAssertLessThan(ended.endedAtNanoseconds, tail.captureDeadlineNanoseconds)
    }

    // MARK: - Recorder with fake streaming hardware

    func testRecorderPlaysToneAtReleaseAndKeepsCapturingThroughTail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tail.wav")
        let hardware = try StreamingTailHardware(url: url)
        let recorder = Recorder(hardware: hardware)
        let tail = RecordingReleaseTail.now()
        var toneAt: UInt64?

        let outcome = await recorder.stopRecording(
            after: tail, playReleaseTone: { toneAt = DispatchTime.now().uptimeNanoseconds },
            shouldEndTailEarly: { false }
        )

        let stoppedAt = try XCTUnwrap(hardware.stoppedAt)
        XCTAssertEqual(outcome?.reason, .captured)
        XCTAssertLessThan(try XCTUnwrap(toneAt), tail.captureDeadlineNanoseconds)
        XCTAssertGreaterThanOrEqual(stoppedAt, tail.captureDeadlineNanoseconds)
        XCTAssertEqual(hardware.stopCount, 1)
        let file = try AVAudioFile(forReading: url)
        let capturedAfterRelease = Double(file.length) / 16_000 - hardware.secondsBefore(tail.releasedAtNanoseconds)
        XCTAssertGreaterThanOrEqual(capturedAfterRelease, 0.2 - 1.0 / 16_000)
    }

    func testRecorderStopsStalledStreamAfterTailPlusGrace() async throws {
        let hardware = try StreamingTailHardware(stalled: true)
        let recorder = Recorder(hardware: hardware)
        let tail = RecordingReleaseTail.now()

        let outcome = await recorder.stopRecording(
            after: tail, playReleaseTone: {}, shouldEndTailEarly: { false }
        )

        XCTAssertEqual(outcome?.reason, .stalled)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(hardware.stoppedAt), tail.waitDeadlineNanoseconds)
        XCTAssertEqual(hardware.stopCount, 1)
    }

    func testProgrammaticStopHasNoTail() async throws {
        let hardware = try StreamingTailHardware()
        let recorder = Recorder(hardware: hardware)
        let requestedAt = DispatchTime.now().uptimeNanoseconds

        await recorder.stopRecording()

        XCTAssertLessThan(try XCTUnwrap(hardware.stoppedAt), requestedAt + RecordingReleaseTail.durationNanoseconds)
        XCTAssertEqual(hardware.capturedThroughReads, 0)
    }

    // MARK: - Engine

    func testShortcutStopRecordsReleaseAndTailEndBeforeClosedWAV() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("engine-tail.wav")
        let hardware = try StreamingTailHardware(url: url)
        let (engine, timing) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
        let tail = RecordingReleaseTail.now()

        await engine.toggleRecord(releaseTail: tail)

        let events = Dictionary(uniqueKeysWithValues: timing.snapshot.map { ($0.phase, $0) })
        let released = try XCTUnwrap(events[.shortcutReleased])
        let tailEnded = try XCTUnwrap(events[.releaseTailEnded])
        let closed = try XCTUnwrap(events[.wavClosed])
        XCTAssertEqual(tailEnded.outcome, .completed)
        XCTAssertGreaterThanOrEqual(tailEnded.elapsedNanoseconds - released.elapsedNanoseconds, RecordingReleaseTail.durationNanoseconds)
        XCTAssertLessThanOrEqual(tailEnded.elapsedNanoseconds, closed.elapsedNanoseconds)
        XCTAssertEqual(hardware.stopCount, 1)
        XCTAssertEqual(engine.recordingState, .idle)
    }

    func testEscapeDuringTailEndsItEarlyAndSavesCanceledRecording() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel-tail.wav")
        let hardware = try StreamingTailHardware(url: url)
        let (engine, timing) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
        // A release handled 10 s from now keeps the tail capturing however late a loaded scheduler delivers Escape.
        let tail = RecordingReleaseTail(releasedAtNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)

        let stop = Task { await engine.toggleRecord(releaseTail: tail) }
        try await waitUntilTailIsCapturing(hardware)
        XCTAssertEqual(engine.recordingState, .transcribing)
        await engine.cancelRecording()
        await stop.value

        XCTAssertLessThan(try XCTUnwrap(hardware.stoppedAt), tail.captureDeadlineNanoseconds)
        XCTAssertEqual(timing.snapshot.first { $0.phase == .releaseTailEnded }?.outcome, .canceled)
        let entries = try engine.modelContext.fetch(FetchDescriptor<Transcription>())
        XCTAssertEqual(entries.map(\.transcriptionStatus), [TranscriptionStatus.canceled.rawValue])
        XCTAssertEqual(engine.recordingState, .idle)
    }

    func testShortcutAndProgrammaticStopsPlayTheSessionStopToneOnce() async throws {
        for tail in [RecordingReleaseTail.now(), nil] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("tone.wav")
            let hardware = try StreamingTailHardware(url: url)
            let (engine, _) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
            var stopToneAt: [UInt64] = []
            engine.activeRecordingDelivery = RecordingDeliverySession(
                destination: .currentApplication,
                playFeedback: { if $0 == .stop { stopToneAt.append(DispatchTime.now().uptimeNanoseconds) } }
            )

            await engine.toggleRecord(releaseTail: tail)
            for _ in 0..<1_000 where stopToneAt.isEmpty { try await Task.sleep(for: .milliseconds(1)) }

            XCTAssertEqual(stopToneAt.count, 1, "tail=\(tail != nil)")
            if tail == nil {
                // Release-tone timing is covered by testRecorderPlaysToneAtReleaseAndKeepsCapturingThroughTail.
                XCTAssertGreaterThan(try XCTUnwrap(stopToneAt.first), try XCTUnwrap(hardware.stoppedAt))
            }
        }
    }

    func testCancelBeforeTheProgrammaticStopToneKeepsItSilent() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel-tone.wav")
        let hardware = try StreamingTailHardware(url: url)
        let (engine, _) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
        var tones: [DictationFeedback.Tone] = []
        engine.activeRecordingDelivery = RecordingDeliverySession(
            destination: .currentApplication, playFeedback: { tones.append($0) }
        )

        await engine.cancelRecording()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(tones, [])
    }

    func testCancelWhileRecordingHasNoTail() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.wav")
        let hardware = try StreamingTailHardware(url: url)
        let (engine, timing) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
        let requestedAt = DispatchTime.now().uptimeNanoseconds

        await engine.cancelRecording()

        XCTAssertLessThan(try XCTUnwrap(hardware.stoppedAt), requestedAt + RecordingReleaseTail.durationNanoseconds)
        XCTAssertEqual(hardware.capturedThroughReads, 0)
        XCTAssertFalse(timing.snapshot.contains { $0.phase == .shortcutReleased || $0.phase == .releaseTailEnded })
    }

    func testStartRequestDuringTailCannotStartBeforeTheOldClipCloses() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("press-tail.wav")
        let hardware = try StreamingTailHardware(url: url)
        let (engine, timing) = try makeRecordingEngine(hardware: hardware, directory: directory, url: url)
        // A release handled 10 s from now keeps the tail open until the test delivers its audio.
        let tail = RecordingReleaseTail(releasedAtNanoseconds: DispatchTime.now().uptimeNanoseconds + 10_000_000_000)

        let stop = Task { await engine.toggleRecord(releaseTail: tail) }
        try await waitUntilTailIsCapturing(hardware)
        var pressFinished = false
        let press = Task {
            await engine.toggleRecord()
            pressFinished = true
        }
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertFalse(pressFinished)
        XCTAssertEqual(hardware.events, [])
        // Cancel before it can reach real preflight, as in RecordingFinalizationTests.
        press.cancel()
        hardware.deliverAudioThroughTail()
        await stop.value
        await press.value

        XCTAssertEqual(hardware.events, ["stop"])
        XCTAssertEqual(timing.snapshot.first { $0.phase == .releaseTailEnded }?.outcome, .completed)
    }

    // MARK: - Shortcut gestures

    func testPressDuringTailFollowsTranscribingGateAndKeepsCooldown() async {
        let fixture = TailHandlerFixture()
        await fixture.down(at: 0, mode: .pushToTalk)
        await fixture.up(at: 1, mode: .pushToTalk)
        XCTAssertEqual(fixture.toggles, 2)
        XCTAssertEqual(fixture.state, .transcribing)

        await fixture.down(at: 1.1, mode: .pushToTalk)
        await fixture.up(at: 1.15, mode: .pushToTalk)
        await fixture.down(at: 1.18, mode: .toggle)
        XCTAssertEqual(fixture.toggles, 2)

        fixture.finishClip()
        // The ignored press inside the tail still starts the 0.25 s cooldown.
        await fixture.down(at: 1.3, mode: .pushToTalk)
        XCTAssertEqual(fixture.toggles, 2)
        await fixture.down(at: 1.36, mode: .pushToTalk)
        XCTAssertEqual(fixture.toggles, 3)
    }

    func testHybridHoldIsJudgedOnPhysicalReleaseNotHandlingTime() async {
        let fixture = TailHandlerFixture()
        await fixture.down(at: 0, mode: .hybrid)
        fixture.now = 0.9
        await fixture.handler.handleShortcutUp(action: .primaryRecording, eventTime: 0.49, mode: .hybrid)
        XCTAssertEqual(fixture.toggles, 1)
        XCTAssertEqual(fixture.state, .recording)

        await fixture.down(at: 1.0, mode: .hybrid)
        XCTAssertEqual(fixture.toggles, 2)
    }

    // MARK: - Helpers

    private func waitUntilTailIsCapturing(_ hardware: StreamingTailHardware) async throws {
        for _ in 0..<1_000 where hardware.capturedThroughReads == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(hardware.capturedThroughReads, 0)
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/release-tail-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeRecordingEngine(
        hardware: StreamingTailHardware, directory: URL, url: URL
    ) throws -> (VoiceInkEngine, RecordingTimingTrace) {
        let container = try ModelContainer(
            for: Transcription.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let models = TranscriptionModelManager(
            whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager()
        )
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: models, recorder: Recorder(hardware: hardware)
        )
        let timing = RecordingTimingTrace()
        let preparation = RecordingTranscriptionPreparation(timing: timing)
        preparation.start(
            resolveConfiguration: { nil }, retireAutoLearn: {}, prepareModel: { _ in }, prepareSession: { _ in nil }
        )
        engine.activeRecordingPreparation = preparation
        engine.recordedFile = url
        engine.recordingState = .recording
        return (engine, timing)
    }
}

private final class FakeClock: @unchecked Sendable {
    var now: UInt64
    init(now: UInt64) { self.now = now }
}

/// Captures continuously from creation and writes elapsed audio to the WAV on stop.
private final class StreamingTailHardware: RecordingHardware, @unchecked Sendable {
    private struct State {
        var file: AVAudioFile?
        var callback: ((Data) -> Void)?
        var stoppedAt: UInt64?
        var stopCount = 0
        var capturedThroughReads = 0
        var capturedThroughOverride: UInt64?
        var events: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let stalled: Bool
    let averagePower: Float = -160
    let peakPower: Float = -160

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0.callback } }
        set { state.withLock { $0.callback = newValue } }
    }
    var stoppedAt: UInt64? { state.withLock { $0.stoppedAt } }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var capturedThroughReads: Int { state.withLock { $0.capturedThroughReads } }
    var events: [String] { state.withLock { $0.events } }

    var capturedThroughNanoseconds: UInt64? {
        let override = state.withLock { state -> UInt64? in
            state.capturedThroughReads += 1
            return state.capturedThroughOverride
        }
        if let override { return override }
        return stalled ? startedAt : DispatchTime.now().uptimeNanoseconds - 5_000_000
    }

    func deliverAudioThroughTail() {
        state.withLock { $0.capturedThroughOverride = .max }
    }

    init(url: URL? = nil, stalled: Bool = false) throws {
        self.stalled = stalled
        var initial = State()
        if let url {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
            initial.file = try AVAudioFile(forWriting: url, settings: format.settings)
        }
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func secondsBefore(_ uptime: UInt64) -> Double { Double(uptime - startedAt) / 1_000_000_000 }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {
        state.withLock { $0.events.append("start") }
    }

    func stopRecording() {
        let stoppedAt = DispatchTime.now().uptimeNanoseconds
        let file = state.withLock { state -> AVAudioFile? in
            state.stopCount += 1
            guard state.stopCount == 1 else { return nil }
            state.stoppedAt = stoppedAt
            state.events.append("stop")
            defer { state.file = nil }
            return state.file
        }
        guard let file else { return }
        let frames = AVAudioFrameCount((stoppedAt - startedAt) * 16_000 / 1_000_000_000)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(frames))
        try? file.write(from: buffer)
    }

    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}

@MainActor
private final class TailHandlerFixture {
    var now: TimeInterval = 0
    var state: RecordingState = .idle
    var visible = false
    var toggles = 0
    var held = false

    lazy var handler = RecordingShortcutModeHandler(
        canHandleShortcutAction: {
            self.state != .transcribing && self.state != .enhancing && self.state != .busy
        },
        isRecorderVisible: { self.visible },
        recordingState: { self.state },
        isShortcutHeld: { _ in self.held },
        finishHeldRecording: {},
        toggleRecorderPanel: { _, _ in
            self.toggles += 1
            switch self.state {
            case .idle:
                self.visible = true
                self.state = .recording
            case .recording:
                // Transcribing is shown at the release while the tail is still captured.
                self.state = .transcribing
            default:
                break
            }
        },
        cancelRecording: { self.visible = false; self.state = .idle },
        now: { self.now }
    )

    func finishClip() {
        state = .idle
        visible = false
    }

    func down(at time: TimeInterval, mode: RecordingShortcutManager.Mode) async {
        now = time
        held = true
        await handler.handleShortcutDown(action: .primaryRecording, eventTime: time, mode: mode)
    }

    func up(at time: TimeInterval, mode: RecordingShortcutManager.Mode) async {
        now = time
        held = false
        await handler.handleShortcutUp(action: .primaryRecording, eventTime: time, mode: mode)
    }
}
