import AVFoundation
import CoreAudio
import FluidAudio
import SwiftData
import XCTest
import os

@testable import VoiceInk

@MainActor
final class NoSpeechGateTests: XCTestCase {
    // MARK: - Level gate

    func testLevelGateDiscardsSilenceNoiseFloorAndDCOffsetWithoutDetector() async {
        let detector = SpeechDetectorFixture(verdict: true)
        let quietNoise = noise(rmsDBFS: -60, count: 16_000)
        let captures: [[Float]] = [[], silence(16_000), tone(amplitude: 0.000_7, count: 16_000), quietNoise,
                                   [Float](repeating: 0.2, count: 16_000)]

        for samples in captures {
            let evaluation = await NoSpeechGate.evaluate(samples: samples, sampleRate: 16_000, detector: detector)

            XCTAssertEqual(evaluation.decision, .nearSilent)
            XCTAssertLessThan(evaluation.levelDBFS, NoSpeechGate.silenceThresholdDBFS)
            XCTAssertNil(evaluation.detectorDuration)
        }
        XCTAssertEqual(detector.receivedSampleCounts, [])
    }

    func testWhisperLevelSpeechPassesLevelGateAndKeepsFullAudioWithoutDetector() async {
        var samples = silence(8_000)
        samples += tone(amplitude: 0.01, count: 1_600)
        samples += silence(6_400)

        let evaluation = await NoSpeechGate.evaluate(samples: samples, sampleRate: 16_000, detector: nil)

        XCTAssertEqual(evaluation.decision, .detectorUnavailable)
        XCTAssertFalse(evaluation.decision.discardsRecording)
        XCTAssertEqual(evaluation.levelDBFS, -43, accuracy: 0.5)
        XCTAssertEqual(evaluation.audioDuration, 1, accuracy: 0.001)
    }

    func testDetectorVerdictDecidesLouderCaptures() async {
        let samples = noise(rmsDBFS: -40, count: 16_000)
        let cases: [(SpeechDetectorFixture, NoSpeechGate.Decision)] = [
            (SpeechDetectorFixture(verdict: true), .speech),
            (SpeechDetectorFixture(verdict: false), .noSpeech),
            (SpeechDetectorFixture(verdict: nil), .detectorUnavailable),
            (SpeechDetectorFixture(failure: CocoaError(.featureUnsupported)), .detectorUnavailable),
        ]

        for (detector, expected) in cases {
            let evaluation = await NoSpeechGate.evaluate(samples: samples, sampleRate: 16_000, detector: detector)

            XCTAssertEqual(evaluation.decision, expected)
            XCTAssertEqual(detector.receivedSampleCounts, [16_000])
            XCTAssertNotNil(evaluation.detectorDuration)
        }
    }

    func testDetectorIsSkippedForAudioThatIsNotSixteenKilohertz() async {
        let detector = SpeechDetectorFixture(verdict: false)

        let evaluation = await NoSpeechGate.evaluate(
            samples: tone(amplitude: 0.1, count: 48_000, sampleRate: 48_000), sampleRate: 48_000, detector: detector
        )

        XCTAssertEqual(evaluation.decision, .detectorUnavailable)
        XCTAssertEqual(detector.receivedSampleCounts, [])
    }

    func testClosedWAVEvaluationIgnoresAudioAfterTheRelease() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tail.wav")
        try writeRecording(silence(16_000) + tone(amplitude: 0.2, count: 8_000), to: url)
        let detector = SpeechDetectorFixture(verdict: false)

        let released = await NoSpeechGate.evaluate(audioURL: url, releasedFrameCount: 16_000, detector: detector)
        let complete = await NoSpeechGate.evaluate(audioURL: url, detector: detector)

        XCTAssertEqual(released?.decision, .nearSilent)
        XCTAssertEqual(try XCTUnwrap(released?.audioDuration), 1, accuracy: 0.001)
        XCTAssertEqual(complete?.decision, .noSpeech)
        XCTAssertEqual(detector.receivedSampleCounts, [24_000])
    }

    func testClosedWAVEvaluationIgnoresTheStartSound() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("start-sound.wav")
        try writeRecording(tone(amplitude: 0.2, count: 8_000) + silence(16_000), to: url)
        let detector = SpeechDetectorFixture(verdict: true)

        let evaluation = await NoSpeechGate.evaluate(audioURL: url, ignoringLeadingFrames: 8_000, detector: detector)

        XCTAssertEqual(evaluation?.decision, .nearSilent)
        XCTAssertEqual(try XCTUnwrap(evaluation?.audioDuration), 1, accuracy: 0.001)
        XCTAssertEqual(detector.receivedSampleCounts, [])
    }

    func testStartSoundWindowCoversOnlyThisRequestsSoundAfterCaptureStarts() {
        let request: UInt64 = 5_000_000_000
        let playback = SoundPlayback(startNanoseconds: request + 10_000_000, duration: 0.456)

        let afterCapture = NoSpeechGate.startSoundFrameCount(
            playback: playback, requestNanoseconds: request, firstAudioNanoseconds: request + 100_000_000
        )
        let withoutFirstAudio = NoSpeechGate.startSoundFrameCount(
            playback: playback, requestNanoseconds: request, firstAudioNanoseconds: nil
        )
        let lateCapture = NoSpeechGate.startSoundFrameCount(
            playback: playback, requestNanoseconds: request, firstAudioNanoseconds: request + 2_000_000_000
        )
        let earlierRequest = NoSpeechGate.startSoundFrameCount(
            playback: playback, requestNanoseconds: request + 20_000_000, firstAudioNanoseconds: nil
        )
        let preview = NoSpeechGate.startSoundFrameCount(
            playback: SoundPlayback(startNanoseconds: request + 3_000_000_000, duration: 0.456),
            requestNanoseconds: request, firstAudioNanoseconds: request + 100_000_000
        )

        XCTAssertEqual(afterCapture, 8_256)
        XCTAssertEqual(withoutFirstAudio, 9_856)
        XCTAssertEqual(lateCapture, 0)
        XCTAssertEqual(earlierRequest, 0)
        XCTAssertEqual(preview, 0)
        XCTAssertEqual(NoSpeechGate.startSoundFrameCount(
            playback: nil, requestNanoseconds: request, firstAudioNanoseconds: nil
        ), 0)
    }

    func testUnreadableRecordingKeepsTheRecording() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("corrupt.wav")
        try Data("not audio".utf8).write(to: url)

        let evaluation = await NoSpeechGate.evaluate(audioURL: url, detector: SpeechDetectorFixture(verdict: false))

        XCTAssertNil(evaluation)
    }

    // MARK: - FluidAudio detector

    func testFluidAudioDetectorUsesGateThresholdAndMinimumSpeech() async throws {
        let manager = RecordingVADManager(segments: [])
        let service = FluidAudioTranscriptionService(
            vadCache: FluidAudioVADCache(loader: { manager }, isEnabled: { true })
        )

        let silent = try await service.containsSpeech(in: silence(16_000))
        manager.segments = [VadSegment(startTime: 0.2, endTime: 0.5)]
        let speech = try await service.containsSpeech(in: silence(16_000))

        XCTAssertEqual(silent, false)
        XCTAssertEqual(speech, true)
        let configuration = try XCTUnwrap(manager.configurations.last)
        XCTAssertEqual(configuration.minSpeechDuration, 0.16, accuracy: 0.000_1)
        let negativeThreshold = try XCTUnwrap(configuration.negativeThreshold)
        XCTAssertEqual(negativeThreshold + configuration.negativeThresholdOffset, 0.4, accuracy: 0.000_1)
        XCTAssertEqual(manager.configurations.count, 2)
    }

    func testFluidAudioDetectorIsUnavailableWhenVADIsDisabled() async throws {
        let manager = RecordingVADManager(segments: [VadSegment(startTime: 0, endTime: 1)])
        let service = FluidAudioTranscriptionService(
            vadCache: FluidAudioVADCache(loader: { manager }, isEnabled: { false })
        )

        let verdict = try await service.containsSpeech(in: silence(16_000))

        XCTAssertNil(verdict)
        XCTAssertTrue(manager.configurations.isEmpty)
    }

    // MARK: - Live recording pipeline

    func testSilentLiveRecordingIsDiscardedWithoutTranscriptionHistoryOrAudio() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silent.wav")
        let detector = SpeechDetectorFixture(verdict: true)
        let fixture = try makeRecording(samples: silence(16_000), url: url, directory: directory, detector: detector)
        let deleted = expectation(forNotification: .transcriptionDeleted, object: nil) { _ in true }

        await fixture.engine.toggleRecord()

        await fulfillment(of: [deleted, fixture.released], timeout: 3)
        XCTAssertTrue(try history(in: fixture.engine).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertGreaterThan(fixture.session.cancelCount, 0)
        XCTAssertEqual(detector.receivedSampleCounts, [])
        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .discarded)
        XCTAssertEqual(outcome(of: .idle, in: fixture.timing), .discarded)
        XCTAssertNil(outcome(of: .asrStarted, in: fixture.timing))
        XCTAssertEqual(fixture.engine.recordingState, .idle)
        XCTAssertEqual(fixture.engine.recordingNotice, String(localized: "No speech detected"))
        XCTAssertEqual(fixture.engine.recordingStatusText, String(localized: "No speech detected"))
        XCTAssertNil(fixture.engine.recordedFile)
    }

    func testLoudStreamingRecordingWithoutDetectedSpeechIsNotFinalized() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("noise.wav")
        let detector = SpeechDetectorFixture(verdict: false)
        let fixture = try makeRecording(
            samples: noise(rmsDBFS: -30, count: 16_000), url: url, directory: directory, detector: detector
        )

        await fixture.engine.toggleRecord()

        await fulfillment(of: [fixture.released], timeout: 3)
        XCTAssertEqual(detector.receivedSampleCounts, [16_000])
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertGreaterThan(fixture.session.cancelCount, 0)
        XCTAssertTrue(try history(in: fixture.engine).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .discarded)
    }

    func testStartSoundHeardByTheMicrophoneDoesNotCountAsSpeech() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("start-sound-only.wav")
        let detector = SpeechDetectorFixture(verdict: true)
        let fixture = try makeRecording(
            samples: tone(amplitude: 0.2, count: 6_400) + silence(16_000), url: url, directory: directory,
            detector: detector, startSoundDuration: 0.3
        )

        await fixture.engine.toggleRecord()

        await fulfillment(of: [fixture.released], timeout: 3)
        XCTAssertEqual(detector.receivedSampleCounts, [])
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertTrue(try history(in: fixture.engine).isEmpty)
        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .discarded)
    }

    func testDetectedSpeechContinuesToTranscription() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("speech.wav")
        let fixture = try makeRecording(
            samples: noise(rmsDBFS: -30, count: 16_000), url: url, directory: directory,
            detector: SpeechDetectorFixture(verdict: true)
        )

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)

        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .completed)
        XCTAssertEqual(try history(in: fixture.engine).first?.transcriptionStatus, TranscriptionStatus.pending.rawValue)
        await fixture.engine.cancelRecording()
        await stop.value
        await fulfillment(of: [fixture.released], timeout: 3)
        XCTAssertEqual(try history(in: fixture.engine).first?.transcriptionStatus, TranscriptionStatus.canceled.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDisabledGateTranscribesSilentRecording() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("disabled.wav")
        let detector = SpeechDetectorFixture(verdict: false)
        let fixture = try makeRecording(
            samples: silence(16_000), url: url, directory: directory, detector: detector, isGateEnabled: false
        )

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [fixture.session.transcribeEntered], timeout: 3)

        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .skipped)
        XCTAssertEqual(detector.receivedSampleCounts, [])
        await fixture.engine.cancelRecording()
        await stop.value
        await fulfillment(of: [fixture.released], timeout: 3)
        XCTAssertEqual(try history(in: fixture.engine).count, 1)
    }

    func testCancelDuringGateEvaluationKeepsCanceledHistory() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.wav")
        let detector = SpeechDetectorFixture(verdict: false, isHeld: true)
        let fixture = try makeRecording(
            samples: noise(rmsDBFS: -30, count: 16_000), url: url, directory: directory, detector: detector
        )

        let stop = Task { await fixture.engine.toggleRecord() }
        await fulfillment(of: [detector.entered], timeout: 3)
        await fixture.engine.cancelRecording()
        detector.release()
        await stop.value
        await fulfillment(of: [fixture.released], timeout: 3)

        let entries = try history(in: fixture.engine)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.transcriptionStatus, TranscriptionStatus.canceled.rawValue)
        XCTAssertEqual(try XCTUnwrap(entries.first?.duration), 1, accuracy: 0.001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(fixture.session.transcribeCount, 0)
        XCTAssertEqual(outcome(of: .speechGate, in: fixture.timing), .canceled)
        XCTAssertNil(fixture.engine.recordingNotice)
    }

    // MARK: - Installed Silero model

    /// Opt-in: `VOICEINK_REAL_VAD=1` with FluidAudio's Silero model installed.
    func testInstalledSileroDetectorSeparatesSpeechFromTonesAndNoise() async throws {
        guard ProcessInfo.processInfo.environment["VOICEINK_REAL_VAD"] == "1" else {
            throw XCTSkip("Set VOICEINK_REAL_VAD=1 to run the installed Silero detector check")
        }
        let manager = try await LocalFluidAudioVAD.load()
        let service = FluidAudioTranscriptionService(
            vadCache: FluidAudioVADCache(loader: { manager }, isEnabled: { true })
        )
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let speech = try synthesizedSpeech(in: directory)
        let peak = speech.map(abs).max() ?? 1
        let whisper = speech.map { $0 / peak * 0.02 }

        let speechVerdict = try await service.containsSpeech(in: speech)
        let whisperGate = await NoSpeechGate.evaluate(samples: whisper, sampleRate: 16_000, detector: service)
        let toneVerdict = try await service.containsSpeech(in: tone(amplitude: 0.1, count: 32_000))
        let noiseVerdict = try await service.containsSpeech(in: noise(rmsDBFS: -35, count: 32_000))

        XCTAssertEqual(speechVerdict, true)
        XCTAssertEqual(whisperGate.decision, .speech, "whisper level \(whisperGate.levelDBFS) dBFS")
        XCTAssertEqual(toneVerdict, false)
        XCTAssertEqual(noiseVerdict, false)
    }

    // MARK: - Fixtures

    private struct RecordingFixture {
        let engine: VoiceInkEngine
        let session: GateSessionFixture
        let timing: RecordingTimingTrace
        let released: XCTestExpectation
    }

    private func makeRecording(
        samples: [Float], url: URL, directory: URL, detector: SpeechDetectorFixture, isGateEnabled: Bool = true,
        startSoundDuration: TimeInterval? = nil
    ) throws -> RecordingFixture {
        let timing = RecordingTimingTrace()
        let startSound = startSoundDuration.map {
            SoundPlayback(startNanoseconds: timing.originNanoseconds, duration: $0)
        }
        let container = try ModelContainer(
            for: Transcription.self, VocabularyWord.self, VocabularySection.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let whisper = WhisperModelManager(modelsDirectory: directory)
        let engine = VoiceInkEngine(
            modelContext: ModelContext(container), whisperModelManager: whisper,
            transcriptionModelManager: TranscriptionModelManager(
                whisperModelManager: whisper, fluidAudioModelManager: FluidAudioModelManager()
            ),
            recorder: Recorder(hardware: try FixtureRecordingHardware(url: url, samples: samples)),
            speechDetector: detector, isNoSpeechGateEnabled: { isGateEnabled }, startSoundPlayback: { startSound }
        )
        let session = GateSessionFixture()
        let released = expectation(description: "recording preparation released")
        let preparation = RecordingTranscriptionPreparation(timing: timing)
        let configuration = TranscriptionRuntimeConfiguration(
            mode: ModeConfig(name: "Gate fixture", isAIEnhancementEnabled: false),
            model: ImportedWhisperModel(fileBaseName: "ggml-small"), languages: ["en"], isRealtimeEnabled: true
        )
        preparation.start(
            resolveConfiguration: { configuration }, retireAutoLearn: {}, prepareModel: { _ in },
            prepareSession: { _ in session }, releaseResources: { _ in released.fulfill() }
        )
        engine.activeRecordingPreparation = preparation
        engine.recordedFile = url
        engine.recordingState = .recording
        return RecordingFixture(engine: engine, session: session, timing: timing, released: released)
    }

    private func outcome(
        of phase: RecordingTimingTrace.Phase, in timing: RecordingTimingTrace
    ) -> RecordingTimingTrace.Outcome? {
        timing.snapshot.first { $0.phase == phase }?.outcome
    }

    private func history(in engine: VoiceInkEngine) throws -> [Transcription] {
        try engine.modelContext.fetch(FetchDescriptor<Transcription>())
    }

    private func makeDirectory() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".tmp/no-speech-gate-tests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func synthesizedSpeech(in directory: URL) throws -> [Float] {
        let url = directory.appendingPathComponent("speech.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000",
            "Please send the quarterly report to the team before Friday.",
        ]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}

private func silence(_ count: Int) -> [Float] {
    [Float](repeating: 0, count: count)
}

private func tone(amplitude: Float, count: Int, sampleRate: Double = 16_000) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * Double.pi * 440 * Double($0) / sampleRate)) }
}

/// Deterministic white noise with the requested RMS level.
private func noise(rmsDBFS: Float, count: Int) -> [Float] {
    var state: UInt64 = 0x9E37_79B9_7F4A_7C15
    let amplitude = pow(10, rmsDBFS / 20) * Float(3).squareRoot()
    return (0..<count).map { _ in
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Float(state >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}

/// Writes the live recorder's format: 16 kHz mono PCM16.
private func writeRecording(_ samples: [Float], to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard !samples.isEmpty else { return }
    let buffer = try XCTUnwrap(
        AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
    )
    buffer.frameLength = AVAudioFrameCount(samples.count)
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
    try file.write(from: buffer)
}

@MainActor
private final class SpeechDetectorFixture: SpeechDetecting {
    private let verdict: Bool?
    private let failure: Error?
    private let isHeld: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    let entered = XCTestExpectation(description: "speech detector entered")
    private(set) var receivedSampleCounts: [Int] = []

    init(verdict: Bool?, isHeld: Bool = false) {
        self.verdict = verdict
        self.failure = nil
        self.isHeld = isHeld
    }

    init(failure: Error) {
        self.verdict = nil
        self.failure = failure
        self.isHeld = false
    }

    func containsSpeech(in samples: [Float]) async throws -> Bool? {
        receivedSampleCounts.append(samples.count)
        entered.fulfill()
        if isHeld, !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        if let failure { throw failure }
        return verdict
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class GateSessionFixture: TranscriptionSession {
    private(set) var transcribeCount = 0
    private(set) var cancelCount = 0
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
            await withCheckedContinuation { continuation = $0 }
        }
        throw CancellationError()
    }

    func cancel() {
        cancelCount += 1
        continuation?.resume()
        continuation = nil
    }
}

private final class RecordingVADManager: FluidAudioVADManaging, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<(segments: [VadSegment], configurations: [VadSegmentationConfig])>

    init(segments: [VadSegment]) {
        state = OSAllocatedUnfairLock(initialState: (segments, []))
    }

    var segments: [VadSegment] {
        get { state.withLock { $0.segments } }
        set { state.withLock { $0.segments = newValue } }
    }
    var configurations: [VadSegmentationConfig] { state.withLock { $0.configurations } }

    func segmentSpeech(_ samples: [Float]) async throws -> [VadSegment] { segments }

    func segmentSpeech(_ samples: [Float], config: VadSegmentationConfig) async throws -> [VadSegment] {
        state.withLock { state in
            state.configurations.append(config)
            return state.segments
        }
    }

    func segmentSpeechAudio(_ samples: [Float]) async throws -> [[Float]] { [samples] }
}

/// Closes a WAV with fixed samples when the recorder stops.
private final class FixtureRecordingHardware: RecordingHardware, @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<((Data) -> Void)?> = OSAllocatedUnfairLock(initialState: nil)
    private let url: URL
    private let samples: [Float]
    let averagePower: Float = -160
    let peakPower: Float = -160
    let recordingError: Error? = nil
    let firstAudioTimestampNanoseconds: UInt64? = nil

    var onAudioChunk: ((Data) -> Void)? {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    init(url: URL, samples: [Float]) throws {
        self.url = url
        self.samples = samples
    }

    func stopRecording() {
        try? writeRecording(samples, to: url)
    }

    func startRecording(toOutputFile url: URL, deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func prepare(deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func switchDevice(to deviceID: AudioDeviceID, selectedInputChannels: [UInt32]?) throws {}
    func invalidatePreparation() {}
    func teardown() {}
}
