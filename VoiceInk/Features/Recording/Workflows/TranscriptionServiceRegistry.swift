import Foundation
import SwiftData
import SwiftUI
import os

@MainActor
class TranscriptionServiceRegistry {
    private weak var modelProvider: (any WhisperModelProvider)?
    private let modelsDirectory: URL
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "TranscriptionServiceRegistry")

    private(set) lazy var localTranscriptionService = WhisperTranscriptionService(
        modelsDirectory: modelsDirectory,
        modelProvider: modelProvider
    )
    private(set) lazy var cloudTranscriptionService = CloudTranscriptionService()
    private(set) lazy var nativeAppleTranscriptionService = NativeAppleTranscriptionService()
    private let providedFluidAudioService: FluidAudioTranscriptionService?
    private(set) lazy var fluidAudioTranscriptionService = providedFluidAudioService ?? FluidAudioTranscriptionService()
    private var cachedTranscribeCppTranscriptionService: TranscribeCppTranscriptionService?

    var transcribeCppTranscriptionService: TranscribeCppTranscriptionService {
        if let cachedTranscribeCppTranscriptionService {
            return cachedTranscribeCppTranscriptionService
        }
        let service = TranscribeCppTranscriptionService()
        cachedTranscribeCppTranscriptionService = service
        return service
    }

    private let idleUnload: IdleModelUnloadCoordinator
    private let activity: IdleModelUnloadCoordinator.Activity
    private let modelLoads = SingleFlightModelLoads()

    init(
        modelProvider: any WhisperModelProvider, modelsDirectory: URL, modelContext: ModelContext,
        fluidAudioService: FluidAudioTranscriptionService? = nil,
        idleUnload: IdleModelUnloadCoordinator? = nil, activity: IdleModelUnloadCoordinator.Activity = .use
    ) {
        self.modelProvider = modelProvider
        self.modelsDirectory = modelsDirectory
        self.modelContext = modelContext
        self.providedFluidAudioService = fluidAudioService
        self.idleUnload = idleUnload ?? .shared
        self.activity = activity
    }

    func service(for provider: ModelProvider) -> TranscriptionService {
        switch provider {
        case .whisper:
            return localTranscriptionService
        case .fluidAudio:
            return fluidAudioTranscriptionService
        case .transcribeCpp:
            return transcribeCppTranscriptionService
        case .nativeApple:
            return nativeAppleTranscriptionService
        default:
            return cloudTranscriptionService
        }
    }

    func transcribe(
        audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext = .currentDefaults
    ) async throws -> String {
        let service = service(for: model.provider)
        logger.debug(
            "Transcribing with \(model.displayName, privacy: .public) using \(String(describing: type(of: service)), privacy: .public)"
        )
        let vocabulary = context.vocabulary ?? CustomVocabularyService.shared.loadSavedVocabulary(from: modelContext)
        return try await idleUnload.perform(activity) {
            try await service.transcribe(
                audioURL: audioURL, model: model, context: context.withVocabulary(vocabulary).scoped(to: model)
            )
        }
    }

    /// Creates a streaming or file-based session for the resolved transcription configuration.
    func createSession(
        for configuration: TranscriptionRuntimeConfiguration, onPartialTranscript: ((String) -> Void)? = nil
    ) -> TranscriptionSession {
        let model = configuration.model

        if shouldUseRealtimeTranscription(for: configuration) {
            let streamingService = StreamingTranscriptionService(
                fluidAudioService: model.provider == .fluidAudio ? fluidAudioTranscriptionService : nil,
                onPartialTranscript: onPartialTranscript
            )
            let fallback = service(for: model.provider)
            return StreamingTranscriptionSession(streamingService: streamingService, fallbackService: fallback)
        } else {
            return FileTranscriptionSession(service: service(for: model.provider))
        }
    }

    /// Nil for batch configurations. Waits for an idle unload in progress so the session loads a fresh model.
    func makeRealtimeSession(
        for configuration: TranscriptionRuntimeConfiguration, onPartialTranscript: ((String) -> Void)? = nil
    ) async -> TranscriptionSession? {
        await waitForPendingUnload()
        guard shouldUseRealtimeTranscription(for: configuration) else { return nil }
        return createSession(for: configuration, onPartialTranscript: onPartialTranscript)
    }

    /// Whether the resolved transcription configuration should use real-time transcription.
    func shouldUseRealtimeTranscription(for configuration: TranscriptionRuntimeConfiguration) -> Bool {
        configuration.isRealtimeEnabled
    }

    func prepareForRecording(
        _ configuration: TranscriptionRuntimeConfiguration, recordingID: UUID,
        whisperModelManager: WhisperModelManager
    ) async throws {
        try Task.checkCancellation()
        await waitForPendingUnload()
        try Task.checkCancellation()
        let model = configuration.model
        let key = SingleFlightModelLoads.Key(provider: model.provider, modelName: model.name)
        if model.provider == .whisper {
            if let localModel = whisperModelManager.availableModels.first(where: { $0.name == model.name }),
                whisperModelManager.whisperContext == nil
            {
                try await modelLoads.run(key) { try await whisperModelManager.loadModel(localModel) }
            }
        } else if let model = model as? FluidAudioModel, !configuration.isRealtimeEnabled {
            // Streaming owns its ASR manager; avoid preparing an unused batch manager concurrently.
            let service = fluidAudioTranscriptionService
            try await modelLoads.run(key) { try await service.loadModel(for: model) }
        } else if let model = model as? TranscribeCppModel {
            let service = transcribeCppTranscriptionService
            try await modelLoads.run(key) { try await service.loadModel(for: model) }
        }
        try Task.checkCancellation()
        if model.provider == .fluidAudio {
            _ = try await fluidAudioTranscriptionService.prepareVAD(recordingID: recordingID, model: model)
        }
    }

    func releaseRecordingPreparation(recordingID: UUID, configuration: TranscriptionRuntimeConfiguration) async {
        guard configuration.model.provider == .fluidAudio else { return }
        await fluidAudioTranscriptionService.releaseVADPreparation(recordingID: recordingID)
    }

    func cleanup() async {
        await fluidAudioTranscriptionService.cleanup()
        cachedTranscribeCppTranscriptionService?.cleanup()
    }

    func beginModelUse() -> IdleModelUnloadCoordinator.Lease {
        idleUnload.begin(activity)
    }

    func waitForPendingUnload() async {
        await idleUnload.waitForPendingUnload()
    }

    func unloadIdleModels() async {
        await fluidAudioTranscriptionService.unloadIdleModels()
        cachedTranscribeCppTranscriptionService?.unloadIdleModel()
    }
}

/// Concurrent preparations of one provider's model never load it twice.
///
/// The first caller runs the load itself, so its cancellation reaches the load as before; later callers wait
/// for it to end. After a successful load they skip it; after a failed or canceled one the next caller loads.
@MainActor
final class SingleFlightModelLoads {
    struct Key: Hashable {
        let provider: ModelProvider
        let modelName: String
    }

    private final class Load {
        var succeeded = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private var loads: [Key: Load] = [:]

    func run(_ key: Key, _ operation: @MainActor () async throws -> Void) async throws {
        while let inFlight = loads[key] {
            await withCheckedContinuation { inFlight.waiters.append($0) }
            try Task.checkCancellation()
            if inFlight.succeeded { return }
        }
        let load = Load()
        loads[key] = load
        defer {
            loads[key] = nil
            load.waiters.forEach { $0.resume() }
        }
        try await operation()
        load.succeeded = true
    }
}
