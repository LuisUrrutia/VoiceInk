import Foundation

extension UserDefaults {
    enum Keys {
        static let audioInputMode = "audioInputMode"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let selectedAudioDeviceModelUID = "selectedAudioDeviceModelUID"
        static let prioritizedDevices = "prioritizedDevices"
        static let affiliatePromotionDismissed = "VoiceInkAffiliatePromotionDismissed"
        static let selectedLanguages = "SelectedLanguages"
        static let selectedLanguage = "SelectedLanguage"
    }

    var selectedTranscriptionLanguages: [String] {
        get {
            if let selection = stringArray(forKey: Keys.selectedLanguages) {
                return TranscriptionLanguageSupport.normalizedSelection(selection)
            }
            return TranscriptionLanguageSupport.normalizedSelection([string(forKey: Keys.selectedLanguage) ?? "en"])
        }
        set {
            let selection = TranscriptionLanguageSupport.normalizedSelection(newValue)
            set(selection, forKey: Keys.selectedLanguages)
            set(TranscriptionLanguageSupport.recognitionLanguage(for: selection), forKey: Keys.selectedLanguage)
        }
    }

    var audioInputModeRawValue: String? {
        get { string(forKey: Keys.audioInputMode) }
        set { setValue(newValue, forKey: Keys.audioInputMode) }
    }

    var selectedAudioDeviceUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceUID) }
    }

    var selectedAudioDeviceModelUID: String? {
        get { string(forKey: Keys.selectedAudioDeviceModelUID) }
        set { setValue(newValue, forKey: Keys.selectedAudioDeviceModelUID) }
    }

    var prioritizedDevicesData: Data? {
        get { data(forKey: Keys.prioritizedDevices) }
        set { setValue(newValue, forKey: Keys.prioritizedDevices) }
    }

    var affiliatePromotionDismissed: Bool {
        get { bool(forKey: Keys.affiliatePromotionDismissed) }
        set { setValue(newValue, forKey: Keys.affiliatePromotionDismissed) }
    }
}
