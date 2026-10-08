import AVFoundation
import Foundation

@MainActor
protocol MicrophoneCapturing: AnyObject {
    func startMicrophoneTest(toOutputFile url: URL) async throws
    func stopRecording() async
    func audioMeterSnapshot() -> AudioMeter
}

extension Recorder: MicrophoneCapturing {}

struct MicrophoneDiagnosticReport: Codable, Equatable, Sendable {
    let frames: Int64
    let sampleRate: Double
    let channels: UInt32
    let peakInputLevel: Double

    var duration: TimeInterval { Double(frames) / sampleRate }

    static func validate(_ url: URL, peakInputLevel: Double) throws -> Self {
        let file = try AVAudioFile(forReading: url)
        guard url.pathExtension.lowercased() == "wav",
            file.length > 0,
            file.fileFormat.sampleRate == 16_000,
            file.fileFormat.channelCount == 1,
            file.fileFormat.commonFormat == .pcmFormatInt16
        else { throw MicrophoneDiagnosticError.invalidAudio }
        return Self(
            frames: file.length, sampleRate: file.fileFormat.sampleRate,
            channels: file.fileFormat.channelCount, peakInputLevel: peakInputLevel
        )
    }
}

enum MicrophoneDiagnosticError: Error { case invalidAudio }

@MainActor
final class MicrophoneDiagnostic: ObservableObject {
    enum Phase: Equatable {
        case idle, starting, recording, closing
        case finished(MicrophoneDiagnosticReport)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .starting, .recording, .closing: true
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var resultURL: URL?
    @Published private(set) var elapsedSeconds = 0
    private let recorder: any MicrophoneCapturing
    private let directory: URL
    private let retainAudio: Bool
    private let canStart: () -> Bool
    private let captureIssue: () -> CaptureReadiness.Issue?
    private let wait: () async throws -> Void
    private var captureTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var cancelRequested = false
    private var stopRequested = false

    var isBusy: Bool { phase.isBusy }

    init(
        recorder: any MicrophoneCapturing,
        directory: URL = VoiceInkPersistence.directoryURL.appendingPathComponent("MicrophoneDiagnostics"),
        retainAudio: Bool = MicrophoneDiagnostic.retainsDiagnosticAudio,
        canStart: @escaping () -> Bool,
        captureIssue: @escaping () -> CaptureReadiness.Issue?,
        wait: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(5)) }
    ) {
        self.recorder = recorder
        self.directory = directory
        self.retainAudio = retainAudio
        self.canStart = canStart
        self.captureIssue = captureIssue
        self.wait = wait
    }

    nonisolated static var retainsDiagnosticAudio: Bool {
        #if DEBUG || LOCAL_BUILD
            true
        #else
            false
        #endif
    }

    @discardableResult
    func start() -> Bool {
        guard !isBusy, canStart() else { return false }
        if let issue = captureIssue() {
            phase = .failed(issue.message)
            return false
        }
        cancelRequested = false
        stopRequested = false
        elapsedSeconds = 0
        resultURL = nil
        phase = .starting
        captureTask = Task { await capture() }
        return true
    }

    func stop() async {
        guard phase == .recording else { return }
        stopRequested = true
        captureTask?.cancel()
        await captureTask?.value
    }

    func cancel() async {
        guard isBusy else { return }
        cancelRequested = true
        captureTask?.cancel()
        await captureTask?.value
    }

    private func capture() async {
        let url = directory.appendingPathComponent("\(UUID().uuidString).wav")
        var peakInputLevel = 0.0
        var didAttemptHardwareStart = false
        var didCloseHardware = false
        defer {
            meterTask?.cancel()
            meterTask = nil
            captureTask = nil
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try Task.checkCancellation()
            didAttemptHardwareStart = true
            try await recorder.startMicrophoneTest(toOutputFile: url)
            try Task.checkCancellation()
            phase = .recording
            let startedAt = Date()
            meterTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    peakInputLevel = max(peakInputLevel, self.recorder.audioMeterSnapshot().peakPower)
                    self.elapsedSeconds = min(5, Int(Date().timeIntervalSince(startedAt)))
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            do { try await wait() } catch is CancellationError {
                guard stopRequested && !cancelRequested else { throw CancellationError() }
            }
            meterTask?.cancel()
            phase = .closing
            await recorder.stopRecording()
            didCloseHardware = true
            guard !cancelRequested else { throw CancellationError() }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let report = try await Task.detached(priority: .utility) {
                try MicrophoneDiagnosticReport.validate(url, peakInputLevel: peakInputLevel)
            }.value
            guard !cancelRequested else { throw CancellationError() }
            if retainAudio {
                resultURL = url
            } else {
                try FileManager.default.removeItem(at: url)
            }
            phase = .finished(report)
        } catch {
            meterTask?.cancel()
            phase = .closing
            if didAttemptHardwareStart && !didCloseHardware { await recorder.stopRecording() }
            try? FileManager.default.removeItem(at: url)
            resultURL = nil
            phase = cancelRequested || error is CancellationError
                ? .idle
                : .failed(String(localized: "Microphone test failed. Check the input and try again."))
        }
    }
}
