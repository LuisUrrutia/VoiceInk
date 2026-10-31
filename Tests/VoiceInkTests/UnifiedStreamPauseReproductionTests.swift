import AVFoundation
import FluidAudio
import Foundation
import XCTest
@testable import VoiceInk

/// Opt-in check of whether the Parakeet Unified stream drops the first words after long pauses, against the
/// whole-clip batch path on the same audio. Pass `TEST_RUNNER_VOICEINK_PAUSE_REPRO_RESULT=<report path>`.
@MainActor
final class UnifiedStreamPauseReproductionTests: XCTestCase {
    private static let sampleRate = 16_000
    // The stream windows by sample count, so feed chunk size does not change its output; 100 ms chunks keep a
    // burst feed inside the streaming service's 2,048-chunk buffer.
    private static let feedChunkSamples = 1_600
    private static let segments = [
        "Let me tell you about the plan for this week.",
        "I will send the notes to the whole team tomorrow.",
        "I think we can finish the review on Friday.",
    ]

    private enum Floor: String, CaseIterable {
        case digitalSilence = "silence"
        case noise50 = "noise-50dBFS"
        case noise35 = "noise-35dBFS+8dB"

        var noiseRMS: Float? {
            switch self {
            case .digitalSilence: nil
            case .noise50: decibels(-50)
            case .noise35: decibels(-35)
            }
        }

        /// Active-speech RMS; the issue-458 case puts speech only about 8 dB above the room.
        var speechRMS: Float {
            self == .noise35 ? decibels(-27) : decibels(-20)
        }
    }

    func testCompareStreamedAndBatchWordsAfterPauses() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["VOICEINK_PAUSE_REPRO_RESULT"] else {
            throw XCTSkip("Set TEST_RUNNER_VOICEINK_PAUSE_REPRO_RESULT=<report path> to compare streamed and batch text")
        }
        guard FluidAudioModelManager().isFluidAudioModelDownloaded(named: "parakeet-unified-0.6b") else {
            throw XCTSkip("Parakeet Unified is not installed")
        }
        let gaps = (environment["VOICEINK_PAUSE_REPRO_GAPS"] ?? "3,8,13").split(separator: ",").compactMap { Double($0) }
        let offsets = (environment["VOICEINK_PAUSE_REPRO_OFFSETS"] ?? "0,0.14,0.28,0.42").split(separator: ",").compactMap { Double($0) }
        let voices = (environment["VOICEINK_PAUSE_REPRO_VOICES"] ?? "Samantha,Daniel,Reed (English (US))")
            .split(separator: ",").map(String.init)
        let floors = (environment["VOICEINK_PAUSE_REPRO_FLOORS"]).map { $0.split(separator: ",").compactMap { Floor(rawValue: String($0)) } }
            ?? Floor.allCases
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
        try await service.prewarmUnifiedModel(isRealtime: true)
        try await service.prewarmUnifiedModel(isRealtime: false)

        let scriptWords = Self.segments.map(words)
        var lines = [
            "Parakeet Unified pause reproduction; stream fed in \(Self.feedChunkSamples)-sample chunks; batch = app whole-clip path with VAD",
            "voice\tfloor\tgap_s\toffset_s\tresume_index\tstream_kept_resume\tbatch_kept_resume\tstream_missing_words\tbatch_missing_words\tstream_text\tbatch_text",
        ]
        var totals = (resumes: 0, streamLost: 0, batchLost: 0, streamMissing: 0, batchMissing: 0)
        for voice in voices {
            let speech = try Self.segments.map { try synthesize($0, voice: voice, in: directory) }
            for floor in floors {
                for gap in gaps {
                    for offset in offsets {
                        let samples = clip(speech: speech, gap: gap + offset, floor: floor)
                        let wav = directory.appendingPathComponent("clip.wav")
                        try AudioProcessor().saveSamplesAsWav(samples: samples, to: wav)
                        let streamed = try await streamedText(samples, model: model, service: service)
                        let batch = try await service.transcribe(
                            audioURL: wav, model: model, context: TranscriptionRequestContext(languages: ["en"])
                        )
                        let streamWords = words(streamed)
                        let batchWords = words(batch)
                        let expected = scriptWords.flatMap { $0 }
                        let streamMissing = expected.count - lcs(expected, streamWords)
                        let batchMissing = expected.count - lcs(expected, batchWords)
                        for index in 1..<scriptWords.count {
                            let resume = Array(scriptWords[index].prefix(3))
                            let streamKept = contains(streamWords, resume)
                            let batchKept = contains(batchWords, resume)
                            totals.resumes += 1
                            totals.streamLost += streamKept ? 0 : 1
                            totals.batchLost += batchKept ? 0 : 1
                            lines.append([
                                voice, floor.rawValue, String(format: "%.0f", gap), String(format: "%.2f", offset), "\(index)",
                                "\(streamKept)", "\(batchKept)", "\(streamMissing)", "\(batchMissing)", streamed, batch,
                            ].joined(separator: "\t"))
                        }
                        totals.streamMissing += streamMissing
                        totals.batchMissing += batchMissing
                    }
                }
            }
        }
        lines.append(
            "TOTAL resumes=\(totals.resumes) stream_lost_resume=\(totals.streamLost) batch_lost_resume=\(totals.batchLost) stream_missing_words=\(totals.streamMissing) batch_missing_words=\(totals.batchMissing)"
        )
        await service.cleanup()
        try lines.joined(separator: "\n").appending("\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        XCTAssertLessThanOrEqual(totals.streamLost, totals.batchLost, "The stream lost resumed words that batch kept")
    }

    private func streamedText(
        _ samples: [Float], model: any TranscriptionModel, service: FluidAudioTranscriptionService
    ) async throws -> String {
        let streaming = StreamingTranscriptionService(fluidAudioService: service)
        try await streaming.startStreaming(model: model, context: TranscriptionRequestContext(languages: ["en"]))
        var lower = 0
        while lower < samples.count {
            let upper = min(samples.count, lower + Self.feedChunkSamples)
            var pcm = samples[lower..<upper].map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
            streaming.sendAudioChunk(pcm.withUnsafeMutableBytes { Data($0) })
            lower = upper
        }
        guard case .finalized(let text) = try await streaming.stopAndFinalize() else {
            XCTFail("The stream fell back to batch; the comparison needs the streamed text")
            return ""
        }
        return text
    }

    private func clip(speech: [[Float]], gap: Double, floor: Floor) -> [Float] {
        let gapSamples = Int(gap * Double(Self.sampleRate))
        let edge = [Float](repeating: 0, count: Self.sampleRate / 2)
        var samples = edge
        for (index, segment) in speech.enumerated() {
            if index > 0 { samples += [Float](repeating: 0, count: gapSamples) }
            let gain = floor.speechRMS / activeRMS(segment)
            samples += segment.map { $0 * gain }
        }
        samples += edge
        guard let noiseRMS = floor.noiseRMS else { return samples }
        // Steady Gaussian room noise under the whole clip, seeded for repeatable runs.
        var generator = SplitMix64(seed: 458)
        for index in samples.indices {
            let u1 = max(Float.leastNonzeroMagnitude, Float(generator.next() >> 40) / Float(1 << 24))
            let u2 = Float(generator.next() >> 40) / Float(1 << 24)
            samples[index] += noiseRMS * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        return samples
    }

    /// RMS over 20 ms frames louder than -55 dBFS, so `say`'s inter-word silence does not lower the level.
    private func activeRMS(_ samples: [Float]) -> Float {
        let frames = stride(from: 0, to: samples.count - 320, by: 320).map { start in
            samples[start..<start + 320].reduce(0) { $0 + $1 * $1 } / 320
        }
        let active = frames.filter { $0 > decibels(-55) * decibels(-55) }
        return (active.reduce(0, +) / Float(max(1, active.count))).squareRoot()
    }

    private func synthesize(_ text: String, voice: String, in directory: URL) throws -> [Float] {
        let url = directory.appendingPathComponent("say.wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "say failed for voice \(voice)")
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
    }

    private func contains(_ words: [String], _ phrase: [String]) -> Bool {
        guard words.count >= phrase.count else { return false }
        return (0...(words.count - phrase.count)).contains { Array(words[$0..<$0 + phrase.count]) == phrase }
    }

    private func lcs(_ lhs: [String], _ rhs: [String]) -> Int {
        var previous = [Int](repeating: 0, count: rhs.count + 1)
        for left in lhs {
            var current = [Int](repeating: 0, count: rhs.count + 1)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = left == right ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

private func decibels(_ value: Float) -> Float { pow(10, value / 20) }

private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E4B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
