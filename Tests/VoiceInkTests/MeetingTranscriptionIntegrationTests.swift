import AVFoundation
import XCTest

@testable import VoiceInk

/// Opt-in: `TEST_RUNNER_VOICEINK_MEETING_MODEL=<FluidAudio model name>` transcribes `say` speech with that
/// installed local model and checks timed words. Downloads nothing.
final class MeetingTranscriptionIntegrationTests: XCTestCase {
    func testInstalledModelReportsOrderedWordTimesForSpeech() async throws {
        let name = ProcessInfo.processInfo.environment["VOICEINK_MEETING_MODEL"] ?? ""
        try XCTSkipIf(name.isEmpty, "Set TEST_RUNNER_VOICEINK_MEETING_MODEL")
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == name && $0.provider == .fluidAudio })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingModel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let speech = directory.appendingPathComponent("speech.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", speech.path, "--data-format=LEI16@16000", "The quarterly budget review starts on Monday morning."]
        try say.run()
        say.waitUntilExit()
        var samples = [Float](repeating: 0, count: 16_000) + (try MeetingTranscriber.readSamples(from: speech))
        samples += [Float](repeating: 0, count: 8_000)
        let service = FluidAudioTranscriptionService()

        let segments = try await service.transcribeTimed(
            samples: samples, model: model, context: TranscriptionRequestContext(languages: ["en"], model: model)
        )
        await service.releaseResources()

        let words = segments.flatMap(\.words)
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("budget"), text)
        XCTAssertTrue(text.contains("monday"), text)
        if MeetingTranscriptionModelChoice.reportsWordTimes(model) {
            XCTAssertGreaterThanOrEqual(words.count, 6)
            // Parakeet TDT words are contiguous, so the first one starts up to about 0.45 s before the speech onset at 1 s
            // (parakeet-tdt-0.6b-v3, 2026-10-31).
            XCTAssertEqual(words.first?.start ?? 0, 0.8, accuracy: 0.4)
            XCTAssertLessThanOrEqual(words.last?.end ?? .infinity, Double(samples.count) / 16_000)
            XCTAssertEqual(words.map(\.start), words.map(\.start).sorted())
        }
    }
}
