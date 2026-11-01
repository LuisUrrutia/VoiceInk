import Foundation

struct TranscriptionRuntimeConfiguration {
    let mode: ModeConfig
    let model: any TranscriptionModel
    let languages: [String]
    let isRealtimeEnabled: Bool

    var metadata: (name: String?, emoji: String?) {
        guard mode.isEnabled else {
            return (nil, nil)
        }
        return (mode.name, mode.icon.value)
    }

    var requestContext: TranscriptionRequestContext {
        TranscriptionRequestContext(languages: languages, model: model)
    }
}

struct TranscriptionFormattingConfiguration {
    let mode: ModeConfig?
    let isTextFormattingEnabled: Bool
}

struct EnhancementRuntimeConfiguration {
    let mode: ModeConfig?
    let isEnabled: Bool
    let prompt: CustomPrompt?
    let provider: AIProvider?
    let modelName: String?
    let useClipboardContext: Bool
    let useSelectedTextContext: Bool
    let useScreenCaptureContext: Bool

    func replacingPrompt(_ prompt: CustomPrompt) -> EnhancementRuntimeConfiguration {
        EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: true,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: useClipboardContext,
            useSelectedTextContext: useSelectedTextContext,
            useScreenCaptureContext: useScreenCaptureContext
        )
    }
}

struct OutputRuntimeConfiguration {
    let mode: ModeConfig?
    let outputMode: ModeOutputMode
    let autoSendKey: FinishAndSendKey
    let customCommand: ModeCustomCommand?
}

/// One dictation's mode and the settings resolved from it, so later global mode changes cannot reach it.
struct DictationModeSnapshot {
    typealias EnhancementResolver = @MainActor (ModeConfig?) -> EnhancementRuntimeConfiguration?

    let mode: ModeConfig?
    let formatting: TranscriptionFormattingConfiguration
    let enhancement: EnhancementRuntimeConfiguration?
    let output: OutputRuntimeConfiguration

    var metadata: (name: String?, emoji: String?) {
        guard let mode, mode.isEnabled else { return (nil, nil) }
        return (mode.name, mode.icon.value)
    }

    /// Dictate Without Processing: the same mode without formatting, enhancement, Respond, custom command or Auto Send.
    var withoutProcessing: DictationModeSnapshot {
        DictationModeSnapshot(
            mode: mode,
            formatting: TranscriptionFormattingConfiguration(mode: formatting.mode, isTextFormattingEnabled: false),
            enhancement: nil,
            output: OutputRuntimeConfiguration(mode: output.mode, outputMode: .paste, autoSendKey: .none, customCommand: nil)
        )
    }

    /// Resolves the latest settings of `modeID`, or of the current mode when it is absent or no longer enabled.
    @MainActor
    static func resolve(
        modeID: UUID?, resolveEnhancement: @escaping EnhancementResolver, modeManager: ModeManager = .shared
    ) -> DictationModeSnapshot {
        resolve(mode: modeManager.resolvedEnabledConfiguration(preferredId: modeID), resolveEnhancement: resolveEnhancement)
    }

    /// Resolves every enabled mode now, so a later choice among them sees only these settings.
    @MainActor
    static func frozenResolver(
        fallbackModeID: UUID?, resolveEnhancement: @escaping EnhancementResolver, modeManager: ModeManager = .shared
    ) -> @MainActor (UUID?) -> DictationModeSnapshot {
        let snapshots = Dictionary(uniqueKeysWithValues: modeManager.enabledConfigurations.map {
            ($0.id, resolve(mode: $0, resolveEnhancement: resolveEnhancement))
        })
        let fallback = resolve(modeID: fallbackModeID, resolveEnhancement: resolveEnhancement, modeManager: modeManager)
        return { modeID in modeID.flatMap { snapshots[$0] } ?? fallback }
    }

    /// A trigger word changes only the dictation that spoke it, plus the global mode for later dictations.
    @MainActor
    static func triggerWordSelection(
        in text: String, resolveEnhancement: @escaping EnhancementResolver, modeManager: ModeManager = .shared
    ) -> (text: String, modeSnapshot: DictationModeSnapshot)? {
        guard let (mode, processedText) = modeManager.getConfigurationForTriggerWord(text) else { return nil }
        modeManager.setActiveConfiguration(mode, isTriggerWord: true)
        return (processedText, resolve(mode: mode, resolveEnhancement: resolveEnhancement))
    }

    @MainActor
    static func resolve(mode: ModeConfig?, resolveEnhancement: EnhancementResolver) -> DictationModeSnapshot {
        DictationModeSnapshot(
            mode: mode,
            formatting: ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode),
            enhancement: resolveEnhancement(mode),
            output: ModeRuntimeResolver.outputConfiguration(mode: mode)
        )
    }

    /// Resolves a mode's enhancement settings from the live service; nil without one.
    @MainActor
    static func enhancementResolver(for enhancementService: AIEnhancementService?) -> EnhancementResolver {
        { mode in
            guard let enhancementService, let aiService = enhancementService.getAIService() else { return nil }
            return ModeRuntimeResolver.currentEnhancementConfiguration(
                mode: mode, enhancementService: enhancementService, aiService: aiService
            )
        }
    }
}

enum ModeTranscriptionModelResolution {
    case noMode
    case noSelection(mode: ModeConfig)
    case modelNotFound(mode: ModeConfig)
    case unavailable(mode: ModeConfig, model: any TranscriptionModel)
    case available(mode: ModeConfig, model: any TranscriptionModel)
}

@MainActor
enum ModeRuntimeResolver {
    static func transcriptionModelResolution(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> ModeTranscriptionModelResolution {
        guard let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration else {
            return .noMode
        }

        guard let modelName = mode.selectedTranscriptionModelName,
            !modelName.isEmpty
        else {
            return .noSelection(mode: mode)
        }

        guard
            let model = TranscriptionModelRegistry.model(
                forSelectionKey: modelName,
                in: transcriptionModelManager.allAvailableModels
            )
        else {
            return .modelNotFound(mode: mode)
        }

        guard transcriptionModelManager.usableModels.contains(where: {
            $0.selectionKey == model.selectionKey
        }) else {
            return .unavailable(mode: mode, model: model)
        }

        return .available(mode: mode, model: model)
    }

    static func transcriptionConfiguration(
        mode: ModeConfig? = nil,
        transcriptionModelManager: TranscriptionModelManager
    ) -> TranscriptionRuntimeConfiguration? {
        transcriptionConfiguration(
            from: transcriptionModelResolution(
                mode: mode,
                transcriptionModelManager: transcriptionModelManager
            )
        )
    }

    static func transcriptionConfiguration(
        from resolution: ModeTranscriptionModelResolution
    ) -> TranscriptionRuntimeConfiguration? {
        guard
            case .available(let mode, let model) = resolution
        else {
            return nil
        }

        let languages = TranscriptionLanguageSupport.validLanguagesOrFallback(mode.transcriptionLanguages, for: model)

        return TranscriptionRuntimeConfiguration(
            mode: mode,
            model: model,
            languages: languages,
            isRealtimeEnabled: TranscriptionRealtimeSupport.isEnabled(
                for: model, modeValue: mode.isRealtimeTranscriptionEnabled)
        )
    }

    static func transcriptionFormattingConfiguration(mode: ModeConfig? = nil) -> TranscriptionFormattingConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return TranscriptionFormattingConfiguration(
            mode: mode,
            isTextFormattingEnabled: mode?.isTextFormattingEnabled
                ?? UserDefaults.standard.bool(forKey: "IsTextFormattingEnabled")
        )
    }

    static func currentEnhancementConfiguration(
        mode: ModeConfig? = nil,
        enhancementService: AIEnhancementService,
        aiService: AIService
    ) -> EnhancementRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
        let provider = resolvedProvider(
            providerName: mode?.selectedAIProvider,
            aiService: aiService
        )
        let prompt =
            provider == .voiceInkRefine
            ? nil
            : resolvedPrompt(
                promptId: mode?.selectedPrompt,
                enhancementService: enhancementService
            )
        let modelName = resolvedEnhancementModelName(
            provider: provider,
            configuredModelName: mode?.selectedAIModel,
            aiService: aiService
        )

        return EnhancementRuntimeConfiguration(
            mode: mode,
            isEnabled: mode?.isAIEnhancementEnabled ?? false,
            prompt: prompt,
            provider: provider,
            modelName: modelName,
            useClipboardContext: provider == .voiceInkRefine ? false : mode?.useClipboardContext ?? false,
            useSelectedTextContext: provider == .voiceInkRefine ? false : mode?.useSelectedTextContext ?? true,
            useScreenCaptureContext: provider == .voiceInkRefine ? false : mode?.useScreenCapture ?? false
        )
    }

    static func outputConfiguration(mode: ModeConfig? = nil) -> OutputRuntimeConfiguration {
        let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration

        return OutputRuntimeConfiguration(
            mode: mode,
            outputMode: mode?.outputMode ?? .paste,
            autoSendKey: mode?.outputMode == .paste ? (mode?.autoSendKey ?? .none) : .none,
            customCommand: mode?.customCommand
        )
    }

    private static func resolvedPrompt(
        promptId: String?,
        enhancementService: AIEnhancementService
    ) -> CustomPrompt? {
        guard let promptId,
            let uuid = UUID(uuidString: promptId)
        else {
            return nil
        }

        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private static func resolvedProvider(
        providerName: String?,
        aiService: AIService
    ) -> AIProvider? {
        if let providerName {
            guard let provider = AIProvider(rawValue: providerName) else {
                return nil
            }
            return aiService.connectedProviders.contains(provider) ? provider : nil
        }

        return aiService.connectedProviders.first
    }

    private static func resolvedEnhancementModelName(
        provider: AIProvider?,
        configuredModelName: String?,
        aiService: AIService
    ) -> String? {
        guard let provider else { return nil }

        if provider == .localCLI {
            return nil
        }

        if provider == .voiceInkRefine {
            return provider.defaultModel
        }

        let models = aiService.availableModels(for: provider)
        if let configuredModelName,
            !configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            (provider.supportsCustomModelID || models.isEmpty || models.contains(configuredModelName))
        {
            return configuredModelName.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let firstModel = models.first {
            return firstModel
        }

        return provider.defaultModel
    }
}
