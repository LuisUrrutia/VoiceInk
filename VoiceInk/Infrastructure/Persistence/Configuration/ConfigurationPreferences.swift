import Foundation

enum ConfigurationPreferences {
    private enum Kind {
        case boolean, string, number, integer, strings, stringMap, json
    }

    private static let kinds: [String: Kind] = {
        var result: [String: Kind] = [:]
        let groups: [(Kind, [String])] = [
            (.boolean, [
                "enableAnnouncements", "VoiceInkChecksForUpdatesOnLaunch", "IsMenuBarOnly", "ShowMenuBarIcon", "ShowLiveTranscript",
                "PinPasteTargetToRecordStart", "restoreClipboardAfterPaste", "isSystemMuteEnabled",
                "isPauseMediaEnabled", "IsTextFormattingEnabled", "IsVADEnabled", "AppendTrailingSpace",
                "PrewarmModelOnWake", "SkipShortEnhancement", "EnhancementRetryOnTimeout",
                "IsAutoLearnDictionaryEnabled", "IsTranscriptionCleanupEnabled", "IsAudioCleanupEnabled",
                "isExperimentalFeaturesEnabled", "useClipboardContext", "useSelectedTextContext",
                "useScreenCaptureContext",
            ]),
            (.string, [
                "AppAppearancePreference", "AppLanguagePreference", "RecorderType", "finishAndSendKey",
                "pasteMethod", "remoteClipboardPushCommand", "CurrentTranscriptionModel", "SelectedLanguage",
                "selectedAIProvider", "selectedPromptId", "activeConfigurationId",
                "ollamaBaseURL", "ollamaSelectedModel", "customProviderBaseURL", "customProviderModel",
                "AutoLearnDictionaryProvider", "AutoLearnDictionaryModel", "AutoLearnDictionaryReviewSchedule",
                "localCLICommandTemplate", "localCLISelectedTemplate",
                "primaryRecordingShortcut", "secondaryRecordingShortcut",
                "primaryRecordingShortcutMode", "secondaryRecordingShortcutMode",
                "audioInputMode", "selectedAudioDeviceUID", "selectedAudioDeviceModelUID",
                "selectedStartSoundSelection", "selectedStopSoundSelection",
                "selectedStartBuiltInSound", "selectedStopBuiltInSound",
                "customStartSoundFilename", "customStopSoundFilename",
                "vocabularySortMode", "wordReplacementSortMode",
            ]),
            (.number, ["clipboardRestoreDelay", "audioResumptionDelay", "localCLITimeoutSeconds", "audioPlaybackRate"]),
            (.integer, [
                "CloudTranscriptionTimeout", "ShortEnhancementWordThreshold", "EnhancementTimeoutSeconds",
                "TranscriptionRetentionMinutes", "AudioRetentionPeriod",
            ]),
            (.strings, ["SelectedLanguages", "FillerWords", "userAddedEmojis"]),
            (.stringMap, ["CustomLanguagePrompts"]),
            (.json, ["modeConfigurationsV2", "customPrompts", "customCloudModels", "customAIProviders", "prioritizedDevices"]),
        ]
        for (kind, keys) in groups {
            for key in keys { result[key] = kind }
        }
        for provider in AIProvider.allCases {
            result["\(provider.rawValue)SelectedModel"] = .string
            result["\(provider.rawValue)CustomModelID"] = .string
        }
        return result
    }()

    private static func kind(for key: String) -> Kind? {
        if let kind = kinds[key] { return kind }
        let name = key.hasSuffix("_cleared") ? String(key.dropLast(8)) : key
        let isShortcut = ShortcutAction.legacyKeyboardShortcutActions.contains { $0.userDefaultsKey == name }
            || (name.hasPrefix("Shortcut_mode_") && UUID(uuidString: String(name.dropFirst(14))) != nil)
        guard isShortcut else { return nil }
        return key.hasSuffix("_cleared") ? .boolean : .json
    }

    static func capture(from defaults: UserDefaults) throws -> [String: ConfigurationValue] {
        let keys = Set(kinds.keys).union(defaults.dictionaryRepresentation().keys.filter { kind(for: $0) != nil })
        var result: [String: ConfigurationValue] = [:]
        for key in keys.sorted() {
            guard let stored = defaults.object(forKey: key) else { continue }
            let value: ConfigurationValue
            if kind(for: key) == .json {
                guard let data = stored as? Data else { throw ConfigurationError.invalid("Invalid stored value for \(key).") }
                var decoded = try JSONDecoder().decode(ConfigurationValue.self, from: data)
                // Old model archives can predate the Keychain migration. Never export that field.
                if key == "customCloudModels", case .array(let models) = decoded {
                    decoded = .array(models.map { model in
                        guard var fields = model.object else { return model }
                        fields.removeValue(forKey: "apiKey")
                        return .object(fields)
                    })
                }
                value = decoded
            } else {
                let data = try JSONSerialization.data(withJSONObject: stored, options: [.fragmentsAllowed, .sortedKeys])
                value = try JSONDecoder().decode(ConfigurationValue.self, from: data)
            }
            try validate(value, key: key)
            result[key] = value
        }
        return result
    }

    static func validate(_ values: [String: ConfigurationValue]) throws {
        for (key, value) in values { try validate(value, key: key) }
    }

    private static func validate(_ value: ConfigurationValue, key: String) throws {
        guard let kind = kind(for: key) else { throw ConfigurationError.invalid("Unknown preference \(key).") }
        if value == .null { return }
        let valid: Bool
        switch (kind, value) {
        case (.boolean, .bool), (.string, .string): valid = true
        case (.number, .number(let number)): valid = number.isFinite && (0...Double(Int32.max)).contains(number)
        case (.integer, .number(let number)):
            valid = number.isFinite && (0...Double(Int32.max)).contains(number) && number.rounded() == number
        case (.strings, .array(let array)):
            valid = array.allSatisfy { if case .string = $0 { return true }; return false }
                && (key != "SelectedLanguages" || !array.isEmpty)
        case (.stringMap, .object(let map)):
            valid = map.values.allSatisfy { if case .string = $0 { return true }; return false }
        case (.json, _):
            try validateArchive(value, key: key)
            valid = true
        default: valid = false
        }
        guard valid else { throw ConfigurationError.invalid("Wrong value type or range for \(key).") }
    }

    private static func validateArchive(_ value: ConfigurationValue, key: String) throws {
        do {
            switch key {
            case "modeConfigurationsV2":
                let modes = try value.decoded(as: [ModeConfig].self)
                try requireUnique(modes.map(\.id), key: key)
                guard modes.filter(\.isDefault).count <= 1,
                    modes.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                else { throw ConfigurationError.invalid("Modes need names and at most one default.") }
            case "customPrompts":
                try requireUnique(value.decoded(as: [CustomPrompt].self).map(\.id), key: key)
            case "customCloudModels":
                guard case .array(let models) = value,
                    models.allSatisfy({ $0.object?["apiKey"] == nil })
                else { throw ConfigurationError.invalid("API keys belong in Keychain, not the configuration file.") }
                try requireUnique(value.decoded(as: [CustomModelBackup].self).map(\.id), key: key)
            case "customAIProviders":
                try requireUnique(value.decoded(as: [CustomAIProviderConfig].self).map(\.id), key: key)
            case "prioritizedDevices":
                try requireUnique(value.decoded(as: [PrioritizedDevice].self).map(\.id), key: key)
            default:
                _ = try value.decoded(as: Shortcut.self)
            }
        } catch let error as ConfigurationError { throw error }
        catch { throw ConfigurationError.invalid("Invalid structure for \(key).") }
    }

    static func requireUnique<T: Hashable>(_ values: [T], key: String) throws {
        guard Set(values).count == values.count else { throw ConfigurationError.invalid("Duplicate identity in \(key).") }
    }

    static func apply(_ values: [String: ConfigurationValue], to defaults: UserDefaults) throws {
        // Prepare every serialized value before changing any preference.
        let encoded = try values.mapValues { try $0.data() }
        for (key, value) in values {
            if value == .null { defaults.removeObject(forKey: key) }
            else if kind(for: key) == .json { defaults.set(encoded[key], forKey: key) }
            else { defaults.set(value.propertyList, forKey: key) }
        }
        if let languages = values["SelectedLanguages"], languages != .null {
            defaults.selectedTranscriptionLanguages = try languages.decoded(as: [String].self)
        } else if let language = values["SelectedLanguage"], case .string(let language) = language {
            defaults.selectedTranscriptionLanguages = [language]
        }
    }
}
