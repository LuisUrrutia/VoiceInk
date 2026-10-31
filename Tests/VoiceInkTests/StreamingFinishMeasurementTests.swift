import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import VoiceInk

/// Opt-in Parakeet Unified stop-to-final measurement through the real streaming service and provider.
/// Pass `TEST_RUNNER_VOICEINK_STREAMING_FINISH_RESULT=<report path>` to `xcodebuild`.
@MainActor
final class StreamingFinishMeasurementTests: XCTestCase {
    private static let sampleRate = 16_000.0
    // AUHAL delivers 512 frames at 48 kHz per render block; the recorder converts each block to 16 kHz.
    private static let chunkSamples = 512.0 / 3.0

    private enum Feed: String {
        case realtime
        case burst
    }

    private struct Clip {
        let target: Int
        let script: String
        let samples: [Float]
        let wav: URL
        var seconds: Double { Double(samples.count) / StreamingFinishMeasurementTests.sampleRate }
    }

    func testMeasureUnifiedStopToFinal() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["VOICEINK_STREAMING_FINISH_RESULT"] else {
            throw XCTSkip("Set TEST_RUNNER_VOICEINK_STREAMING_FINISH_RESULT=<report path> to measure streaming finish")
        }
        let runs = Int(environment["VOICEINK_STREAMING_FINISH_RUNS"] ?? "") ?? 3
        let targets = (environment["VOICEINK_STREAMING_FINISH_CLIPS"] ?? "0,1,3,10,20,30,90").split(separator: ",").compactMap { Int($0) }
        let feeds = (environment["VOICEINK_STREAMING_FINISH_FEEDS"] ?? "realtime,burst").split(separator: ",")
            .compactMap { Feed(rawValue: String($0)) }
        try await requireUnifiedModel(allowDownload: environment["VOICEINK_UNIFIED_DOWNLOAD"] == "1")
        let previousOfflineMode = ModelHub.offlineMode
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = previousOfflineMode }

        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first {
            FluidAudioModelManager.isParakeetUnifiedModel(named: $0.name)
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = FluidAudioTranscriptionService(vadCache: FluidAudioVADCache(isEnabled: { true }))
        let clock = ContinuousClock()
        var lines = ["Parakeet Unified streaming finish, chunk=\(String(format: "%.2f", Self.chunkSamples)) samples, runs=\(runs)"]
        var loadStart = clock.now
        try await service.prewarmUnifiedModel(isRealtime: true)
        lines.append("streaming model load ms=\(milliseconds(clock.now - loadStart))")
        loadStart = clock.now
        try await service.prewarmUnifiedModel(isRealtime: false)
        lines.append("batch model load ms=\(milliseconds(clock.now - loadStart))")
        lines.append("load at start: \(loadAverage())")
        lines.append("clip\tseconds\tfeed\trun\toutcome\tstop_ms\tdrain_ms\tcommit_ms\twait_ms\tbatch_ms\tstream_words\tbatch_words\tstream_vs_batch_diff\tload")

        let clips = try targets.map { try makeClip(seconds: $0, in: directory) }
        // Warm both paths once so the first measured run does not include first-inference compilation.
        if let warmup = clips.first(where: { $0.target > 0 }) {
            _ = try await streamedText(warmup, feed: .burst, model: model, service: service)
            _ = try await service.transcribe(audioURL: warmup.wav, model: model, context: TranscriptionRequestContext(languages: ["en"]))
        }
        for run in 1...runs {
            // Interleave clip lengths and feeds so background load affects every configuration alike.
            for clip in (run.isMultiple(of: 2) ? clips.reversed() : clips) {
                for feed in (run.isMultiple(of: 2) ? feeds.reversed() : feeds) {
                    let streamed = try await streamedText(clip, feed: feed, model: model, service: service)
                    let batchStart = clock.now
                    let batch = try await service.transcribe(
                        audioURL: clip.wav, model: model, context: TranscriptionRequestContext(languages: ["en"])
                    )
                    let batchDuration = clock.now - batchStart
                    let streamWords = words(streamed.text ?? "")
                    let batchWords = words(batch)
                    lines.append([
                        clip.target == 0 ? "silence" : "\(clip.target)", String(format: "%.1f", clip.seconds), feed.rawValue, "\(run)",
                        streamed.text == nil ? "fallback" : "stream",
                        milliseconds(streamed.stop), milliseconds(streamed.phases.drain), milliseconds(streamed.phases.commit),
                        milliseconds(streamed.phases.wait), milliseconds(batchDuration),
                        "\(streamWords.count)", "\(batchWords.count)", "\(wordDistance(streamWords, batchWords))", loadAverage(),
                    ].joined(separator: "\t"))
                }
            }
        }
        lines.append("load at end: \(loadAverage())")
        await service.cleanup()
        try lines.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    private func streamedText(
        _ clip: Clip, feed: Feed, model: any TranscriptionModel, service: FluidAudioTranscriptionService
    ) async throws -> (text: String?, stop: Duration, phases: StreamingFinishPhases) {
        let streaming = StreamingTranscriptionService(fluidAudioService: service)
        try await streaming.startStreaming(model: model, context: TranscriptionRequestContext(languages: ["en"]))
        let chunks = Self.pcm16Chunks(clip.samples)
        let clock = ContinuousClock()
        let start = clock.now
        for (index, chunk) in chunks.enumerated() {
            if feed == .realtime {
                let end = Double(index + 1) * Self.chunkSamples / Self.sampleRate
                try await clock.sleep(until: start + .seconds(end))
            }
            streaming.sendAudioChunk(chunk)
        }
        let stopStart = clock.now
        let result = try await streaming.stopAndFinalize()
        let stop = clock.now - stopStart
        guard case .finalized(let text) = result else {
            return (nil, stop, streaming.lastFinishPhases)
        }
        return (text, stop, streaming.lastFinishPhases)
    }

    static func pcm16Chunks(_ samples: [Float]) -> [Data] {
        var chunks: [Data] = []
        var index = 0
        var lower = 0
        while lower < samples.count {
            index += 1
            let upper = min(samples.count, Int((Double(index) * chunkSamples).rounded(.down)))
            var pcm = samples[lower..<upper].map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
            chunks.append(pcm.withUnsafeMutableBytes { Data($0) })
            lower = upper
        }
        return chunks
    }

    private func makeClip(seconds: Int, in directory: URL) throws -> Clip {
        if seconds == 0 {
            // Three seconds of digital silence: what the stream returns when nobody speaks.
            let wav = directory.appendingPathComponent("silence.wav")
            let samples = [Float](repeating: 0, count: 48_000)
            try AudioProcessor().saveSamplesAsWav(samples: samples, to: wav)
            return Clip(target: 0, script: "", samples: samples, wav: wav)
        }
        let sentences = [
            "Please send the quarterly report to the finance team before Friday afternoon.",
            "I think we should move the design review to next Tuesday at three.",
            "The new build fixes the crash when you open a large spreadsheet.",
            "Remind me to call the dentist and book a cleaning for next month.",
            "Our customers asked for a darker theme and faster search results.",
            "I will review the pull request after lunch and leave my comments.",
            "The train to Boston leaves at seven fifteen from platform nine.",
            "Add milk, eggs, coffee and two loaves of bread to the shopping list.",
        ]
        // `say` speaks about 2.7 words per second; size the script to the requested length.
        var script: [String] = []
        var words = 0
        while Double(words) < Double(seconds) * 2.7 {
            let sentence = sentences[script.count % sentences.count]
            script.append(sentence)
            words += sentence.split(separator: " ").count
        }
        if seconds == 1 { script = ["Okay."] }
        if seconds == 3 { script = ["Please send the report before Friday."] }
        let text = script.joined(separator: " ")
        let wav = directory.appendingPathComponent("clip-\(seconds).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", wav.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let file = try AVAudioFile(forReading: wav, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Clip(target: seconds, script: text, samples: Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))), wav: wav)
    }

    private func requireUnifiedModel(allowDownload: Bool) async throws {
        let manager = FluidAudioModelManager()
        if manager.isFluidAudioModelDownloaded(named: "parakeet-unified-0.6b") { return }
        guard allowDownload else {
            throw XCTSkip("Parakeet Unified is not installed; set TEST_RUNNER_VOICEINK_UNIFIED_DOWNLOAD=1 to use the app's download path")
        }
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.compactMap { $0 as? FluidAudioModel }.first {
            FluidAudioModelManager.isParakeetUnifiedModel(named: $0.name)
        })
        manager.startDownload(model)
        // The download task registers itself asynchronously, so poll for installation with a bound.
        for _ in 0..<1_800 where !manager.isFluidAudioModelDownloaded(named: model.name) {
            try await Task.sleep(for: .seconds(1))
        }
        guard manager.isFluidAudioModelDownloaded(named: "parakeet-unified-0.6b") else {
            throw XCTSkip("Parakeet Unified download did not complete")
        }
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    private func wordDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    private func loadAverage() -> String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "?" }
        return String(format: "%.2f", loads[0])
    }

    private func milliseconds(_ duration: Duration?) -> String {
        guard let duration else { return "-" }
        let components = duration.components
        return String(format: "%.1f", Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
    }
}
