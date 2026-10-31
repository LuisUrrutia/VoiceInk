import Combine
import Foundation
import SwiftData
import os

@MainActor
final class ModelPrewarmService: ObservableObject {
    private let transcriptionModelManager: TranscriptionModelManager
    private let whisperModelManager: WhisperModelManager
    private let modelContext: ModelContext
    private let fluidAudioService: FluidAudioTranscriptionService
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ModelPrewarm")
    private let idleUnload: IdleModelUnloadCoordinator
    private var createdServiceRegistry: TranscriptionServiceRegistry?
    private var serviceRegistry: TranscriptionServiceRegistry {
        if let createdServiceRegistry { return createdServiceRegistry }
        let registry = TranscriptionServiceRegistry(
            modelProvider: whisperModelManager,
            modelsDirectory: whisperModelManager.modelsDirectory,
            modelContext: modelContext,
            idleUnload: idleUnload,
            activity: .maintenance
        )
        createdServiceRegistry = registry
        return registry
    }
    private let prewarmAudioURL = Bundle.main.url(forResource: "sound7", withExtension: "wav")
    private let prewarmEnabledKey = "PrewarmModelOnWake"
    private var lifecycleCancellable: AnyCancellable?

    init(
        transcriptionModelManager: TranscriptionModelManager, whisperModelManager: WhisperModelManager,
        modelContext: ModelContext, fluidAudioService: FluidAudioTranscriptionService,
        idleUnload: IdleModelUnloadCoordinator? = nil
    ) {
        self.idleUnload = idleUnload ?? .shared
        self.transcriptionModelManager = transcriptionModelManager
        self.whisperModelManager = whisperModelManager
        self.modelContext = modelContext
        self.fluidAudioService = fluidAudioService
        lifecycleCancellable = LifecycleObserver.shared.publisher(for: .systemDidWake).sink {
            [weak self] _ in
            Task { @MainActor in
                self?.schedulePrewarm()
            }
        }
        schedulePrewarmOnAppLaunch()
    }

    // MARK: - Trigger Handlers

    /// Trigger on app launch (cold start)
    private func schedulePrewarmOnAppLaunch() {
        logger.notice("App launched, scheduling prewarm")
        Task {
            try? await Task.sleep(for: .seconds(3))
            await performPrewarm()
        }
    }

    /// Trigger on wake from sleep
    private func schedulePrewarm() {
        logger.notice("Mac woke from sleep, scheduling prewarm")
        Task {
            try? await Task.sleep(for: .seconds(3))
            await performPrewarm()
        }
    }

    // MARK: - Core Prewarming Logic

    private func performPrewarm() async {
        guard shouldPrewarm() else { return }

        guard
            let transcriptionConfiguration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )
        else {
            logger.notice("No model selected, skipping prewarm")
            return
        }
        let currentModel = transcriptionConfiguration.model

        logger.notice("Prewarming \(currentModel.displayName, privacy: .public)")
        let startTime = Date()

        do {
            if currentModel.provider == .fluidAudio,
                FluidAudioModelManager.isParakeetUnifiedModel(named: currentModel.name)
            {
                try await idleUnload.perform(.maintenance) {
                    try await fluidAudioService.prewarmUnifiedModel(
                        isRealtime: transcriptionConfiguration.isRealtimeEnabled
                    )
                }
            } else {
                guard let audioURL = prewarmAudioURL else {
                    logger.error("❌ Prewarm audio file (sound7.wav) not found")
                    return
                }
                let _ = try await serviceRegistry.transcribe(
                    audioURL: audioURL,
                    model: currentModel,
                    context: transcriptionConfiguration.requestContext
                )
            }
            let duration = Date().timeIntervalSince(startTime)

            logger.notice("Prewarm completed in \(String(format: "%.2f", duration), privacy: .public)s")

        } catch {
            logger.error("❌ Prewarm failed: \(error, privacy: .public)")
        }
    }

    // MARK: - Validation

    /// Frees what this service's own registry keeps resident after a prewarm.
    func unloadIdleModels() async {
        await createdServiceRegistry?.unloadIdleModels()
    }

    private func shouldPrewarm() -> Bool {
        // Check if user has enabled prewarming
        let isEnabled = UserDefaults.standard.bool(forKey: prewarmEnabledKey)
        guard isEnabled else {
            logger.notice("Prewarm disabled by user")
            return false
        }

        // Launch and wake are not uses: the next dictation reloads a model the idle timer freed.
        guard idleUnload.allowsPrewarm else {
            logger.notice("Skipping prewarm - the model was unloaded after being idle")
            return false
        }

        // Prewarm only local runtimes that benefit from retained preparation.
        guard
            let model = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: transcriptionModelManager
            )?.model
        else {
            return false
        }

        switch model.provider {
        case .whisper, .fluidAudio:
            return true
        default:
            logger.notice("Skipping prewarm - cloud models don't need it")
            return false
        }
    }

}
