import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum CloudTranscriptionSettings {
    static let timeoutKey = "CloudTranscriptionTimeout"
    static let defaultTimeout = 30

    static var timeout: TimeInterval {
        let stored = UserDefaults.standard.integer(forKey: timeoutKey)
        return TimeInterval(stored > 0 ? stored : defaultTimeout)
    }
}

enum OnboardingSettings {
    static let completedV2Key = "hasCompletedOnboardingV2"
    static let preparedV2Key = "hasPreparedOnboardingV2"
}

enum AppDefaults {
    static func registerDefaults() {
        AutoLearnSettings.registerDefaults()
        UserDefaults.standard.register(defaults: registeredValues())
        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }

    static func registeredValues(labsFeatures: [LabsFeature] = LabsFeature.all) -> [String: Any] {
        [
            // Onboarding & General
            OnboardingSettings.completedV2Key: false,
            OnboardingSettings.preparedV2Key: false,
            "enableAnnouncements": true,

            // Clipboard
            PasteTargetSettings.key: true,
            "restoreClipboardAfterPaste": true,
            "clipboardRestoreDelay": 2.0,
            SmartPunctuation.settingsKey: false,
            "useAppleScriptPaste": false,

            // Audio & Media
            "isSystemMuteEnabled": true,
            MediaController.loweringKey: false,
            MediaController.loweringLevelKey: MediaController.defaultLoweringLevel,
            "audioResumptionDelay": 0.0,
            "isPauseMediaEnabled": false,
            UserDefaults.Keys.keepMicrophoneReady: false,
            MeetingSettings.showsRecordingIndicatorKey: true,
            MeetingSettings.detectsCallsKey: true,
            UserDefaults.Keys.avoidsBluetoothDefaultMicrophone: true,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.done.builtInSoundKey: CustomSoundManager.SoundType.done.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.error.builtInSoundKey: CustomSoundManager.SoundType.error.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            "AppendTrailingSpace": true,
            NoSpeechGateSettings.isEnabledKey: true,
            "RecorderType": "mini",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,
            CloudTranscriptionSettings.timeoutKey: CloudTranscriptionSettings.defaultTimeout,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,

            // UI & Behavior
            AppIconVisibility.dockHiddenKey: false,
            AppIconVisibility.menuBarVisibleKey: true,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Enhancement
            "SkipShortEnhancement": false,
            "ShortEnhancementWordThreshold": 3,
            EnhancementRequestSettings.timeoutKey: EnhancementRequestSettings.defaultTimeoutSeconds,
            EnhancementRequestSettings.retryOnTimeoutKey: EnhancementRequestSettings.defaultRetryOnTimeout,

            // Model
            "PrewarmModelOnWake": true,

        ].merging(TranscriptionTextDefaults.preferences) { _, shared in shared }
            .merging(Labs.registeredDefaults(for: labsFeatures)) { current, _ in current }
    }
}
