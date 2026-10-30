import CoreML
import FluidAudio
import Foundation

/// Decoder input after VAD and the result whose token timings use that input's clock.
struct DecodedSpeech {
    let samples: [Float]
    let result: ASRResult
    let timeline: SpeechTimeline
    let vadApplied: Bool
}

final class Transcriber {
    let manager: AsrManager
    let settings: Settings
    let language: Language?
    let log: (String) -> Void
    var vad: VadManager?
    var attemptedVAD = false

    convenience init(options: Options, settings: Settings, log: @escaping (String) -> Void) async throws {
        try await self.init(model: options.model, modelDirectory: options.modelDirectory, settings: settings, log: log)
    }

    init(model: String, modelDirectory: URL?, settings: Settings, log: @escaping (String) -> Void) async throws {
        ModelHub.offlineMode = true
        let version: AsrModelVersion = model == "v2" ? .v2 : model == "ultra" ? .ultra : .v3
        let directory = modelDirectory ?? AsrModels.defaultCacheDirectory(for: version)
        guard AsrModels.modelsExist(at: directory, version: version) else {
            throw CLIError.message("Parakeet \(model) is missing or incomplete at \(directory.path). Install it in VoiceInk Models first; this command never downloads models.")
        }
        let models = try AsrModels.loadLocal(from: directory, version: version, encoderPrecision: .int8)
        manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.settings = settings
        self.language = version == .v2 ? nil : Language(rawValue: settings.language)
        self.log = log
    }

    func transcribe(_ samples: [Float]) async throws -> Transcript {
        let duration = Double(samples.count) / 16_000
        guard let decoded = try await decode(samples) else {
            return Transcript(text: "", segments: [], duration: duration, speechDuration: 0, vadApplied: false)
        }
        return transcript(decoded.result.text, decoded: decoded, duration: duration)
    }

    /// Nil for digital silence; a decoded result with empty text when VAD finds no speech.
    func decode(_ samples: [Float]) async throws -> DecodedSpeech? {
        guard !samples.isEmpty else { throw CLIError.message("Audio is empty") }
        if samples.allSatisfy({ abs($0) <= 1e-10 }) { return nil }
        var ranges = [0..<samples.count]
        var vadApplied = false
        if settings.vadEnabled, let vad = await cachedVAD() {
            do {
                let segments = try await vad.segmentSpeech(samples)
                ranges = segments.compactMap {
                    let start = max(0, min(samples.count, $0.startSample(sampleRate: 16_000)))
                    let end = max(start, min(samples.count, $0.endSample(sampleRate: 16_000)))
                    return end > start ? start..<end : nil
                }
                vadApplied = true
            } catch is CancellationError { throw CancellationError() }
            catch { log("VAD failed; using full audio: \(error.localizedDescription)") }
        }
        let timeline = try SpeechTimeline(ranges: ranges, originalCount: samples.count)
        guard timeline.speechCount > 0 else {
            let empty = ASRResult(text: "", confidence: 0, duration: 0, processingTime: 0)
            return DecodedSpeech(samples: [], result: empty, timeline: timeline, vadApplied: vadApplied)
        }
        var speech = vadApplied ? ranges.flatMap { Array(samples[$0]) } : samples
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if speech.count < minimum { speech += [Float](repeating: 0, count: minimum - speech.count) }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(speech, decoderState: &state, language: language)
        return DecodedSpeech(samples: speech, result: result, timeline: timeline, vadApplied: vadApplied)
    }

    func transcript(_ rawText: String, decoded: DecodedSpeech, duration: Double) -> Transcript {
        let timeline = decoded.timeline
        let vadApplied = decoded.vadApplied
        guard timeline.speechCount > 0 else {
            return Transcript(text: "", segments: [], duration: duration, speechDuration: 0, vadApplied: vadApplied)
        }
        let text = settings.process(TextNormalizer.shared.normalizeSentence(rawText))
        let tokens = decoded.result.tokenTimings ?? []
        var segments: [TimedSegment] = []
        var group: [TokenTiming] = []
        func flush() {
            guard let first = group.first, let last = group.last else { return }
            let segmentText = settings.process(TextNormalizer.shared.normalizeSentence(group.map(\.token).joined()), paragraphs: false)
            let start = timeline.originalTime(first.startTime, isEnd: false)
            let end = max(start, timeline.originalTime(last.endTime, isEnd: true))
            if !segmentText.isEmpty, end > start { segments.append(TimedSegment(start: start, end: end, text: segmentText)) }
            group.removeAll(keepingCapacity: true)
        }
        for token in tokens where token.startTime.isFinite && token.endTime.isFinite && token.endTime >= token.startTime {
            if let first = group.first, let last = group.last,
               (token.endTime - first.startTime > 6 && token.token.hasPrefix(" ")) || token.startTime - last.endTime > 0.8 { flush() }
            group.append(token)
        }
        flush()
        if tokens.isEmpty, !text.isEmpty {
            segments = [TimedSegment(start: timeline.originalTime(0, isEnd: false),
                                     end: timeline.originalTime(Double(timeline.speechCount) / 16_000, isEnd: true), text: text)]
            log("Model returned no token timings; emitting one cue over the speech range")
        }
        return Transcript(text: text, segments: segments, duration: duration,
                          speechDuration: Double(timeline.speechCount) / 16_000, vadApplied: vadApplied)
    }

    private func cachedVAD() async -> VadManager? {
        if attemptedVAD { return vad }
        attemptedVAD = true
        let url = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
            .appendingPathComponent(ModelNames.VAD.sileroVadFile)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("Cached Silero VAD is missing; using full audio without downloading")
            return nil
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: url, configuration: config)
            vad = VadManager(config: VadConfig(defaultThreshold: 0.7), vadModel: model)
        } catch { log("Cached VAD cannot load; using full audio: \(error.localizedDescription)") }
        return vad
    }
    func cleanup() async { await manager.cleanup() }
}
