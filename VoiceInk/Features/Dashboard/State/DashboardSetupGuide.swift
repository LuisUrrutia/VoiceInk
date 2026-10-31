import Foundation

/// Home setup prompts that disappear once the user has done what each one suggests.
enum DashboardSetupGuide {
    enum Step: Equatable {
        case chooseModel, createFirstMode, customizeModes, setShortcuts, addVocabulary
    }

    struct Configuration {
        var modes: [ModeConfig]
        var installedLocalModelNames: Set<String>
        var hasRecordingShortcut: Bool
        var hasDictionaryEntries: Bool
    }

    /// Model names available without a download: the built-in Apple Speech and the starter default.
    private static let initialModelNames: Set<String> = ["apple-speech", StarterModeFactory.defaultTranscriptionModelName]

    static func steps(for configuration: Configuration) -> [Step] {
        let modes = configuration.modes
        let hasConfiguredModes = hasUserModes(modes) || hasCustomizedDefaultMode(modes)
        var steps: [Step] = []

        if !hasConfiguredModes, !hasChangedDefaultModel(modes),
            configuration.installedLocalModelNames.isSubset(of: initialModelNames)
        {
            steps.append(.chooseModel)
        }
        if !modes.contains(where: \.isEnabled) {
            steps.append(.createFirstMode)
        } else if !hasConfiguredModes {
            steps.append(.customizeModes)
        }
        if !configuration.hasRecordingShortcut { steps.append(.setShortcuts) }
        if !configuration.hasDictionaryEntries { steps.append(.addVocabulary) }
        return steps
    }

    /// Before the first completed dictation the card introduces recording; afterwards it appears only to report a problem.
    static func showsCaptureReadiness(
        hasCompletedDictation: Bool,
        readiness: CaptureReadiness,
        hotkey: RecordingHotkeyAvailability,
        hasRecordingError: Bool
    ) -> Bool {
        guard hasCompletedDictation else { return true }
        // A model check in progress is not a problem; showing it would flash the card on every launch.
        let issues = readiness.issues(for: .shortcutDictation, hotkey: hotkey).filter { $0 != .model(.checking) }
        return hasRecordingError || !issues.isEmpty || !readiness.issues(for: .paste).isEmpty
    }

    private static func hasUserModes(_ modes: [ModeConfig]) -> Bool {
        modes.contains { !StarterModeCatalog.ids.contains($0.id) }
    }

    private static func hasChangedDefaultModel(_ modes: [ModeConfig]) -> Bool {
        guard let modelName = modes.first(where: \.isDefault)?.selectedTranscriptionModelName else { return false }
        return modelName != StarterModeFactory.defaultTranscriptionModelName
    }

    private static func hasCustomizedDefaultMode(_ modes: [ModeConfig]) -> Bool {
        guard let mode = modes.first(where: \.isDefault) else { return false }
        guard let template = StarterModeCatalog.templates.first(where: \.isDefault), mode.id == template.id else {
            return true
        }
        return mode.name != template.name
            || mode.icon != template.icon
            || mode.isAIEnhancementEnabled != template.usesAIEnhancement
            || mode.selectedPrompt != template.promptId?.uuidString
            || mode.outputMode != template.outputMode
            || mode.useSelectedTextContext != template.useSelectedTextContext
            || mode.useScreenCapture != template.useScreenCapture
            || mode.useClipboardContext
            || !mode.isTextFormattingEnabled
            || mode.autoSendKey != .none
            || mode.customCommand != nil
            || !mode.triggerWords.isEmpty
            || !(mode.appConfigs ?? []).isEmpty
            || !(mode.urlConfigs ?? []).isEmpty
            || !(mode.triggerGroups ?? []).isEmpty
            || mode.transcriptionLanguages != ["auto"]
    }
}
