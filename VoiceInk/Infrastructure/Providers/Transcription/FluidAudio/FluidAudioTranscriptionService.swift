import FluidAudio
import Foundation
import os.log

class FluidAudioTranscriptionService: TranscriptionService {
    /// Model file access; tests replace it to observe model lifetime without installed models.
    struct ModelRuntime {
        var loadAsrModels: @Sendable (AsrModelVersion) async throws -> AsrModels
        var loadUnifiedModel: @MainActor (any UnifiedModel) async throws -> Void
        var transcribeUnified: @Sendable (UnifiedAsrManager, [Float]) async throws -> String

        static let installed = ModelRuntime(
            loadAsrModels: { version in
                let cacheDirectory = AsrModels.defaultCacheDirectory(for: version)
                guard AsrModels.modelsExist(at: cacheDirectory, version: version) else {
                    throw AsrModelsError.loadingFailed(
                        "Parakeet model files are incomplete. Download the model from AI Models."
                    )
                }
                return try await AsrModels.load(
                    from: cacheDirectory,
                    configuration: nil,
                    version: version,
                    encoderPrecision: .int8
                )
            },
            loadUnifiedModel: { try await $0.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory()) },
            transcribeUnified: { try await $0.transcribe($1) }
        )
    }

    @MainActor private(set) lazy var unifiedStreamingModels = UnifiedModelCache(
        makeManager: {
            StreamingUnifiedAsrManager(
                config: FluidAudioModelManager.parakeetUnifiedStreamingConfig,
                encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision
            )
        },
        load: runtime.loadUnifiedModel
    )
    @MainActor private(set) lazy var unifiedBatchModels = UnifiedModelCache(
        makeManager: { UnifiedAsrManager(encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision) },
        load: runtime.loadUnifiedModel
    )
    private let runtime: ModelRuntime
    private var asrManager: AsrManager?
    private var nemotronAsrManager: StreamingNemotronMultilingualAsrManager?
    private let vadCache: FluidAudioVADCache
    private var activeVersion: AsrModelVersion?
    private var activeNemotronModelName: String?
    private var cachedModels: AsrModels?
    private var loadingTask: (version: AsrModelVersion, task: Task<AsrModels, Error>)?
    private let audioConverter = AudioConverter()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "FluidAudioTranscriptionService")

    init(vadCache: FluidAudioVADCache = FluidAudioVADCache(), runtime: ModelRuntime = .installed) {
        self.vadCache = vadCache
        self.runtime = runtime
    }

    func prepareVAD(recordingID: UUID, model: any TranscriptionModel) async throws -> Bool {
        guard model.provider == .fluidAudio else {
            await releaseVADPreparation(recordingID: recordingID)
            return false
        }
        do {
            return try await vadCache.prepare(recordingID: recordingID, modelName: model.name)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD preparation unavailable; preserving full-audio fallback")
            return false
        }
    }

    func releaseVADPreparation(recordingID: UUID) async {
        await vadCache.release(recordingID: recordingID)
    }

    @MainActor
    func prewarmUnifiedModel(isRealtime: Bool) async throws {
        if isRealtime {
            _ = try await unifiedStreamingModels.getOrLoad()
        } else {
            _ = try await unifiedBatchModels.getOrLoad()
        }
    }

    private func version(for model: any TranscriptionModel) -> AsrModelVersion {
        FluidAudioModelManager.asrVersion(for: model.name)
    }

    static func languageHint(from selectedLanguage: String?, model: any TranscriptionModel) -> Language? {
        guard model.provider == .fluidAudio else {
            return nil
        }
        return FluidAudioModelManager.languageHint(from: selectedLanguage, for: model.name)
    }

    // Unified managers retain their models independently of per-recording resources.
    private func cleanupLoadedManagers() async {
        await nemotronAsrManager?.cleanup()
        await asrManager?.cleanup()

        nemotronAsrManager = nil
        asrManager = nil
        activeVersion = nil
        activeNemotronModelName = nil
    }

    private func ensureModelsLoaded(for version: AsrModelVersion) async throws {
        if asrManager != nil, activeVersion == version {
            return
        }

        // Clean up existing manager but preserve cachedModels for reuse
        await cleanupLoadedManagers()

        let models = try await getOrLoadModels(for: version)

        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.activeVersion = version
    }

    private func ensureNemotronModelsLoaded(named modelName: String) async throws {
        if nemotronAsrManager != nil, activeNemotronModelName == modelName {
            return
        }

        await cleanupLoadedManagers()

        let manager = StreamingNemotronMultilingualAsrManager()
        try await manager.loadModels(from: FluidAudioModelManager.nemotronCacheDirectory(for: modelName))
        self.nemotronAsrManager = manager
        self.activeNemotronModelName = modelName
    }

    // Returns cached models or loads from disk; deduplicates concurrent loads
    func getOrLoadModels(for version: AsrModelVersion) async throws -> AsrModels {
        if let cached = cachedModels, cached.version == version {
            return cached
        }

        // Deduplicate concurrent loads for the same version
        if let (existingVersion, existingTask) = loadingTask, existingVersion == version {
            return try await existingTask.value
        }

        let loadAsrModels = runtime.loadAsrModels
        let task = Task { try await loadAsrModels(version) }
        loadingTask = (version, task)

        do {
            let models = try await task.value
            self.cachedModels = models
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            return models
        } catch {
            // Only clear if we're still the current loading task
            if loadingTask?.version == version {
                self.loadingTask = nil
            }
            throw error
        }
    }

    func loadModel(for model: FluidAudioModel) async throws {
        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            // Realtime Nemotron uses a dedicated streaming manager; batch loads lazily in transcribe().
            return
        }

        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            try await prewarmUnifiedModel(isRealtime: false)
            return
        }

        try await ensureModelsLoaded(for: version(for: model))
    }

    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
    {
        if FluidAudioModelManager.isParakeetUnifiedModel(named: model.name) {
            return try await unifiedBatchModels.withModel { manager in
                let samples = try await preparedSpeechAudio(from: audioURL)
                try Task.checkCancellation()
                return samples.isEmpty ? "" : try await runtime.transcribeUnified(manager, samples)
            }
        }

        if FluidAudioModelManager.isNemotronModel(named: model.name) {
            try await ensureNemotronModelsLoaded(named: model.name)
            guard let nemotronAsrManager else {
                throw ASRError.notInitialized
            }

            let compatibleLanguage = TranscriptionLanguageSupport.validLanguageOrFallback(
                context.language,
                for: model
            )
            let languageHint = FluidAudioModelManager.nemotronLanguageHint(from: compatibleLanguage)
            await nemotronAsrManager.setLanguage(languageHint)
            await nemotronAsrManager.reset()

            var speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            let trailingSilenceSamples = 16_000
            let maxSingleChunkSamples = 240_000
            if speechAudio.count + trailingSilenceSamples <= maxSingleChunkSamples {
                speechAudio += [Float](repeating: 0, count: trailingSilenceSamples)
            }

            _ = try await nemotronAsrManager.process(samples: speechAudio)
            let text = try await nemotronAsrManager.finish()
            return text
        }

        let targetVersion = version(for: model)
        try await ensureModelsLoaded(for: targetVersion)

        guard let asrManager = asrManager else {
            throw ASRError.notInitialized
        }

        let languageHint = Self.languageHint(
            from: context.language,
            model: model
        )
        var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
        let result: ASRResult
        if UserDefaults.standard.bool(forKey: "IsVADEnabled") {
            let speechAudio = try await preparedSpeechAudio(from: audioURL)
            guard !speechAudio.isEmpty else { return "" }
            result = try await asrManager.transcribe(
                speechAudio,
                decoderState: &decoderState,
                language: languageHint
            )
        } else {
            result = try await asrManager.transcribe(
                audioURL,
                decoderState: &decoderState,
                language: languageHint
            )
        }

        return result.text
    }

    private func loadAudioSamples(from audioURL: URL) throws -> [Float] {
        try audioConverter.resampleAudioFile(audioURL)
    }

    private func preparedSpeechAudio(from audioURL: URL) async throws -> [Float] {
        let samples = try loadAudioSamples(from: audioURL)
        return try await preparedSpeechAudio(in: samples)
    }

    func preparedSpeechAudio(in samples: [Float]) async throws -> [Float] {
        guard let segments = try await detectedSpeechAudio(in: samples) else {
            return samples
        }

        var speechAudio = segments.flatMap { $0 }
        guard !speechAudio.isEmpty else { return [] }
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        if speechAudio.count < minimumSamples {
            speechAudio += [Float](repeating: 0, count: minimumSamples - speechAudio.count)
        }
        return speechAudio
    }

    // Streaming callers retain each segment's original position for word timestamps.
    func detectedSpeechSegments(in samples: [Float]) async throws -> [VadSegment]? {
        do {
            try Task.checkCancellation()
            guard let manager = try await vadCache.manager() else { return nil }
            let segments = try await manager.segmentSpeech(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    // Nil means VAD is disabled or unavailable; callers preserve the original audio.
    private func detectedSpeechAudio(in samples: [Float]) async throws -> [[Float]]? {
        do {
            try Task.checkCancellation()
            guard let manager = try await vadCache.manager() else { return nil }
            let segments = try await manager.segmentSpeechAudio(samples)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.notice("VAD failed; using full audio: \(error, privacy: .public)")
            return nil
        }
    }

    /// Frees resident ASR models, including the cached models `cleanup()` keeps; the next use reloads them.
    /// The VAD cache is left alone: its recording lease owns it and pipeline cleanup already releases it.
    @MainActor
    func unloadIdleModels() async {
        await unifiedBatchModels.unloadIfIdle()
        await unifiedStreamingModels.unloadIfIdle()
        guard loadingTask == nil else { return }
        cachedModels = nil
        await cleanupLoadedManagers()
    }

    // Releases ASR/VAD resources but preserves cached models for reuse
    func cleanup() async {
        await vadCache.cleanup()
        await cleanupLoadedManagers()
    }

}

extension FluidAudioTranscriptionService: SpeechDetecting {
    // FluidAudio derives the entry threshold from the negative threshold plus its offset.
    static let noSpeechGateSegmentation = VadSegmentationConfig(
        minSpeechDuration: NoSpeechGate.minimumSpeechDuration,
        negativeThreshold: NoSpeechGate.speechProbabilityThreshold - 0.15,
        negativeThresholdOffset: 0.15
    )

    /// Uses the installed Silero model only; nil when VAD is disabled or unavailable.
    func containsSpeech(in samples: [Float]) async throws -> Bool? {
        guard let manager = try await vadCache.manager() else { return nil }
        return try await !manager.segmentSpeech(samples, config: Self.noSpeechGateSegmentation).isEmpty
    }
}
