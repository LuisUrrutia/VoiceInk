import FluidAudio
import Foundation
import XCTest
@testable import VoiceInk

@MainActor
final class ParakeetCLIIntegrationTests: XCTestCase {
    func testOptInSampleMatchesSupportedAppPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let samplePath = environment["VOICEINK_CLI_SAMPLE"],
              let resultPath = environment["VOICEINK_CLI_RESULT"] else {
            throw XCTSkip("Set VOICEINK_CLI_SAMPLE and VOICEINK_CLI_RESULT for the installed-model comparison")
        }
        let version: AsrModelVersion = .v3
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: version), version: version) else {
            throw XCTSkip("Parakeet v3 is not installed")
        }
        let previousOfflineMode = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = previousOfflineMode }
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-tdt-0.6b-v3" })
        let sample = URL(fileURLWithPath: samplePath)
        let wav = sample.deletingLastPathComponent().appendingPathComponent("app-comparison.wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let processor = AudioProcessor()
        let samples = try await processor.processAudioToSamples(sample)
        try processor.saveSamplesAsWav(samples: samples, to: wav)
        let service = FluidAudioTranscriptionService()

        let raw = try await service.transcribe(audioURL: wav, model: model, context: TranscriptionRequestContext(languages: ["en"]))
        await service.cleanup()
        let appText = TranscriptionOutputFilter.filter(raw)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: resultPath))) as? [String: Any])

        XCTAssertEqual(json["text"] as? String, appText)
        XCTAssertFalse(appText.isEmpty)
    }
}
