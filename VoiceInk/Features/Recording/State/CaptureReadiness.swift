import Foundation

enum CapturePermission: Equatable {
    case notDetermined, granted, denied, restricted
}

enum RecordingHotkeyAvailability: Equatable {
    case unconfigured, unavailable, needsAccessibility, available

    var message: String {
        switch self {
        case .unconfigured: String(localized: "Set a recording shortcut in Settings.")
        case .unavailable: String(localized: "Recording shortcut is not active. Refresh it in Settings.")
        case .needsAccessibility: String(localized: "This shortcut needs Accessibility permission.")
        case .available: String(localized: "Recording shortcut is active.")
        }
    }
}

enum CaptureModelReadiness: Equatable {
    case ready, checking, noMode, noSelection, unavailable, notInstalled, providerMissing, invalidCustomModel

    var message: String {
        switch self {
        case .ready: String(localized: "Transcription model is configured.")
        case .checking: String(localized: "Checking transcription setup…")
        case .noMode: String(localized: "Create or enable a mode to dictate.")
        case .noSelection: String(localized: "Select a transcription model for this mode.")
        case .unavailable: String(localized: "The selected transcription model is unavailable.")
        case .notInstalled: String(localized: "Download the selected transcription model.")
        case .providerMissing: String(localized: "Configure the selected transcription provider in Models.")
        case .invalidCustomModel: String(localized: "Check the custom model endpoint and model name in Models.")
        }
    }

    static func evaluate(
        model: any TranscriptionModel,
        supportedOnOS: Bool,
        installedNames: Set<String>?,
        configuredProviderKeys: Set<String>?,
        configuredCustomModelIDs: Set<UUID>?
    ) -> Self {
        guard supportedOnOS else { return .unavailable }
        switch model.provider {
        case .whisper, .fluidAudio, .transcribeCpp:
            guard let installedNames else { return .checking }
            return installedNames.contains(model.name) ? .ready : .notInstalled
        case .nativeApple:
            return .ready
        case .custom:
            guard let custom = model as? CustomCloudModel,
                let url = URL(string: custom.apiEndpoint),
                ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                url.host?.isEmpty == false,
                !custom.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return .invalidCustomModel }
            guard let configuredCustomModelIDs else { return .checking }
            return configuredCustomModelIDs.contains(custom.id) ? .ready : .providerMissing
        default:
            guard let provider = CloudProviderRegistry.provider(for: model.provider) else { return .unavailable }
            guard let configuredProviderKeys else { return .checking }
            return configuredProviderKeys.contains(provider.providerKey.lowercased()) ? .ready : .providerMissing
        }
    }
}

struct CaptureReadiness: Equatable {
    enum Operation { case microphoneTest, onScreenDictation, shortcutDictation, paste }
    enum Issue: Equatable {
        case microphonePermission(CapturePermission), microphoneUnavailable, model(CaptureModelReadiness)
        case hotkey(RecordingHotkeyAvailability), accessibility

        var message: String {
            switch self {
            case .microphonePermission(.restricted): String(localized: "Microphone access is restricted by macOS.")
            case .microphonePermission: String(localized: "Allow microphone access to record.")
            case .microphoneUnavailable: String(localized: "No usable microphone. Connect an input or open the lid.")
            case .model(let state): state.message
            case .hotkey(let state): state.message
            case .accessibility: String(localized: "Allow Accessibility to paste into other apps.")
            }
        }
    }

    var microphonePermission: CapturePermission
    var hasMicrophone: Bool
    var accessibilityGranted: Bool
    var model: CaptureModelReadiness
    var usesPaste: Bool

    func issues(
        for operation: Operation,
        hotkey: RecordingHotkeyAvailability = .unconfigured
    ) -> [Issue] {
        if operation == .paste {
            return usesPaste && !accessibilityGranted ? [.accessibility] : []
        }
        var issues: [Issue] = []
        if microphonePermission != .granted { issues.append(.microphonePermission(microphonePermission)) }
        if !hasMicrophone { issues.append(.microphoneUnavailable) }
        if operation != .microphoneTest && model != .ready { issues.append(.model(model)) }
        if operation == .shortcutDictation && hotkey != .available { issues.append(.hotkey(hotkey)) }
        return issues
    }
}

enum CaptureFeedback: Equatable {
    case idle, setupBlocked, starting, recording, transcribing, error

    static func resolve(state: RecordingState, hasSetupIssues: Bool, hasError: Bool) -> Self {
        switch state {
        case .starting: .starting
        case .recording: .recording
        case .transcribing, .enhancing, .busy: .transcribing
        case .idle: hasError ? .error : (hasSetupIssues ? .setupBlocked : .idle)
        }
    }

    var title: String {
        switch self {
        case .idle: String(localized: "Ready to record")
        case .setupBlocked: String(localized: "Dictation needs setup")
        case .starting: String(localized: "Starting microphone…")
        case .recording: String(localized: "Recording · microphone active")
        case .transcribing: String(localized: "Processing recording…")
        case .error: String(localized: "Recording could not complete")
        }
    }
}
