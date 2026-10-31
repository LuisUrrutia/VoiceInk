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
                "PinPasteTargetToRecordStart", "restoreClipboardAfterPaste", "isSystemMuteEnabled", "isSystemAudioLoweringEnabled",
                "isPauseMediaEnabled", "IsTextFormattingEnabled", "IsVADEnabled", "AppendTrailingSpace",
                "PrewarmModelOnWake", "SkipShortEnhancement", "EnhancementRetryOnTimeout",
                "IsAutoLearnDictionaryEnabled", "IsTranscriptionCleanupEnabled", "IsAudioCleanupEnabled",
                "isExperimentalFeaturesEnabled", "useClipboardContext", "useSelectedTextContext",
                "useScreenCaptureContext", "SmartPunctuationEnabled", "IsAutomaticVocabularyCorrectionEnabled",
                NoSpeechGateSettings.isEnabledKey,
                UserDefaults.Keys.keepMicrophoneReady,
                UserDefaults.Keys.avoidsBluetoothDefaultMicrophone,
            ]),
            (.string, [
                "AppAppearancePreference", "AppLanguagePreference", "RecorderType", "finishAndSendKey",
                "pasteMethod", "remoteClipboardPushCommand", "CurrentTranscriptionModel", "SelectedLanguage",
                "selectedAIProvider", "selectedPromptId", "activeConfigurationId",
                "ollamaBaseURL", "ollamaSelectedModel", "customProviderBaseURL", "customProviderModel",
                "localCLICommandTemplate", "localCLISelectedTemplate",
                "primaryRecordingShortcut", "secondaryRecordingShortcut",
                "primaryRecordingShortcutMode", "secondaryRecordingShortcutMode",
                "audioInputMode", "selectedAudioDeviceUID", "selectedAudioDeviceModelUID",
                "selectedStartSoundSelection", "selectedStopSoundSelection",
                "selectedStartBuiltInSound", "selectedStopBuiltInSound",
                "customStartSoundFilename", "customStopSoundFilename",
                "selectedDoneSoundSelection", "selectedErrorSoundSelection",
                "selectedDoneBuiltInSound", "selectedErrorBuiltInSound",
                "customDoneSoundFilename", "customErrorSoundFilename",
                "vocabularySortMode", "wordReplacementSortMode",
            ]),
            (.number, [
                "clipboardRestoreDelay", "audioResumptionDelay", "systemAudioLoweringLevel", "localCLITimeoutSeconds",
                "audioPlaybackRate",
            ]),
            (.integer, [
                "CloudTranscriptionTimeout", "ShortEnhancementWordThreshold", "EnhancementTimeoutSeconds",
                "TranscriptionRetentionMinutes", "AudioRetentionPeriod", "AutoLearnDictionaryMinimumCorrections",
            ]),
            (.strings, ["SelectedLanguages", "FillerWords", "userAddedEmojis"]),
            (.stringMap, ["CustomLanguagePrompts"]),
            (.json, [
                "modeConfigurationsV2", "customPrompts", "customCloudModels", "customAIProviders", "prioritizedDevices",
                "audioInputChannelsByDeviceUID",
            ]),
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

    /// Removed by Auto Learn's local review; older files stay valid. Values are ignored, never applied or captured.
    private static let retiredKeys: Set<String> = [
        "AutoLearnDictionaryProvider", "AutoLearnDictionaryModel", "AutoLearnDictionaryReviewSchedule",
    ]

    private static func kind(for key: String) -> Kind? {
        if let kind = kinds[key] { return kind }
        let name = key.hasSuffix("_cleared") ? String(key.dropLast(8)) : key
        guard shortcutAction(for: name) != nil else { return nil }
        return key.hasSuffix("_cleared") ? .boolean : .json
    }

    private static func shortcutAction(for key: String) -> ShortcutAction? {
        if let action = ShortcutAction.legacyKeyboardShortcutActions.first(where: { $0.userDefaultsKey == key }) { return action }
        if key.hasPrefix("Shortcut_mode_"), let id = UUID(uuidString: String(key.dropFirst(14))) {
            let action = ShortcutAction.mode(id)
            return action.userDefaultsKey == key ? action : nil
        }
        return nil
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
            result[key] = value
        }
        try validate(result, defaults: defaults)
        return result
    }

    static func validate(_ values: [String: ConfigurationValue], defaults: UserDefaults? = nil) throws {
        for (key, value) in values where !retiredKeys.contains(key) { try validate(value, key: key) }
        let modes: [ModeConfig]
        if let value = values["modeConfigurationsV2"], value != .null {
            modes = try value.decoded(as: [ModeConfig].self)
        } else {
            let current = values["modeConfigurationsV2"] == .null ? nil : defaults?.data(forKey: "modeConfigurationsV2")
            let data = current ?? defaults?.data(forKey: "powerModeConfigurationsV2")
            modes = data.flatMap { try? JSONDecoder().decode([ModeConfig].self, from: $0) } ?? []
        }
        let actions = ShortcutAction.legacyKeyboardShortcutActions + modes.map { ShortcutAction.mode($0.id) }
        func effectiveKey(_ key: String, legacy: String?) -> String {
            let isPresent = values[key].map { $0 != .null } ?? (defaults?.object(forKey: key) != nil)
            return isPresent ? key : legacy ?? key
        }
        var shortcuts: [(key: String, shortcut: Shortcut)] = []
        for action in actions {
            let key = action.userDefaultsKey
            let legacyKey = ModeShortcutMigration.legacyKey(for: action)
            let clearedKey = effectiveKey("\(key)_cleared", legacy: legacyKey.map { "\($0)_cleared" })
            let cleared = values[clearedKey].map { $0 == .bool(true) } ?? (defaults?.bool(forKey: clearedKey) == true)
            guard !cleared else { continue }
            let sourceKey = effectiveKey(key, legacy: legacyKey)
            let shortcut: Shortcut?
            if let value = values[sourceKey] {
                shortcut = value == .null ? nil : try value.decoded(as: Shortcut.self)
            } else {
                shortcut = defaults?.data(forKey: sourceKey).flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            }
            guard let shortcut else { continue }
            guard ShortcutValidator.bindingValidationError(for: shortcut, action: action) == nil else {
                throw ConfigurationError.invalid("Shortcut not allowed for \(key).")
            }
            if let conflict = shortcuts.first(where: { $0.shortcut.conflicts(with: shortcut) }) {
                throw ConfigurationError.invalid("\(key) conflicts with \(conflict.key).")
            }
            shortcuts.append((key, shortcut))
        }
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
            case "audioInputChannelsByDeviceUID":
                _ = try value.decoded(as: [String: [UInt32]].self)
            default:
                let shortcut = try value.decoded(as: Shortcut.self)
                guard let action = shortcutAction(for: key),
                    ShortcutValidator.bindingValidationError(for: shortcut, action: action) == nil
                else { throw ConfigurationError.invalid("Shortcut not allowed for \(key).") }
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
        for (key, value) in values where !retiredKeys.contains(key) {
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
