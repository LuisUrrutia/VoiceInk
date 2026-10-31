import Foundation

enum ModelRecommendationRole: String, Equatable, Sendable {
    case recommended
    case fastest
    case mostAccurate

    var title: String {
        switch self {
        case .recommended: String(localized: "Recommended")
        case .fastest: String(localized: "Fastest")
        case .mostAccurate: String(localized: "Most accurate")
        }
    }

    func title(for language: String) -> String {
        switch self {
        case .recommended: String(format: String(localized: "Recommended for %@"), language)
        case .fastest: String(format: String(localized: "Fastest for %@"), language)
        case .mostAccurate: String(format: String(localized: "Most accurate for %@"), language)
        }
    }
}

/// Speech models suggested for a transcription language selection.
///
/// Adapted from Hex (MIT): `choices_for_runtime` in
/// https://github.com/anomalyco/hex/blob/1018aecdbbc82a1dd655964fde800b7319ccf571/src/transcription_models.rs
/// and the FLEURS comparison in its `docs/plans/language-recommendations.md`. docs/model-recommendations.md
/// lists the evidence per language and the Hex entries VoiceInk omits.
struct ModelRecommendations: Equatable, Sendable {
    static let none = ModelRecommendations(languages: [], suggestions: [])

    private struct Suggestion: Equatable, Sendable {
        let name: String
        let role: ModelRecommendationRole

        init(_ name: String, _ role: ModelRecommendationRole) {
            self.name = name
            self.role = role
        }
    }

    let languages: [String]
    private let suggestions: [Suggestion]

    static let whisperLargeV3Turbo = "ggml-large-v3-turbo"
    static let parakeetV3 = "parakeet-tdt-0.6b-v3"
    static let parakeetUnified = "parakeet-unified-0.6b"
    static let cohereTranscribe = "cohere-transcribe"
    static let senseVoiceSmall = "sensevoice-small"

    private static let providers: [String: ModelProvider] = [
        whisperLargeV3Turbo: .whisper, parakeetV3: .fluidAudio, parakeetUnified: .fluidAudio,
        cohereTranscribe: .transcribeCpp, senseVoiceSmall: .transcribeCpp,
    ]

    init(languages: [String]) {
        let selection = TranscriptionLanguageSupport.normalizedSelection(languages)
        let keys = selection.map(Self.recommendationKey)
        // VoiceInk transcribes multiple selected languages with automatic detection.
        self.init(languages: selection, suggestions: Self.suggestions(forKey: keys.count > 1 ? "auto" : keys[0]))
    }

    private init(languages: [String], suggestions: [Suggestion]) {
        self.languages = languages
        self.suggestions = suggestions
    }

    var isEmpty: Bool { suggestions.isEmpty }

    func role(for model: any TranscriptionModel) -> ModelRecommendationRole? {
        guard let suggestion = suggestions.first(where: { $0.name == model.name }),
            Self.providers[model.name] == model.provider, supportsSelection(model)
        else {
            return nil
        }
        return suggestion.role
    }

    /// The model's position among the suggestions, for ordering; nil when it is not suggested.
    func rank(of model: any TranscriptionModel) -> Int? {
        guard role(for: model) != nil else { return nil }
        return suggestions.firstIndex { $0.name == model.name }
    }

    var languageDescription: String {
        languages == ["auto"]
            ? String(localized: "automatic language detection")
            : TranscriptionLanguageSupport.displayNames(for: languages)
    }

    private func supportsSelection(_ model: any TranscriptionModel) -> Bool {
        let supported = Set(model.supportedLanguages.keys.map(Self.recommendationKey))
        let keys = languages.map(Self.recommendationKey)
        guard keys.allSatisfy(supported.contains) else { return false }
        return keys.count == 1 || TranscriptionLanguageSupport.supportsMultipleSelection(for: model)
    }

    /// Compares BCP-47 locales such as Apple Speech's `es-ES` by their language, and Hex's
    /// Filipino (`fil`) as Whisper's Tagalog (`tl`), which Hex sends to Whisper for it.
    private static func recommendationKey(_ code: String) -> String {
        let language = code.split(separator: "-").first.map { String($0).lowercased() } ?? code
        return language == "fil" ? "tl" : language
    }

    private static func suggestions(forKey key: String) -> [Suggestion] {
        switch key {
        case "auto":
            [Suggestion(whisperLargeV3Turbo, .recommended)]
        case "en":
            [Suggestion(parakeetUnified, .recommended), Suggestion(cohereTranscribe, .mostAccurate)]
        case "zh":
            [Suggestion(senseVoiceSmall, .fastest)]
        case "ja":
            [Suggestion(whisperLargeV3Turbo, .recommended), Suggestion(senseVoiceSmall, .fastest)]
        case "el":
            [Suggestion(cohereTranscribe, .recommended)]
        case "fi", "sv", "da":
            [Suggestion(whisperLargeV3Turbo, .recommended), Suggestion(parakeetV3, .fastest)]
        case "mt":
            [Suggestion(parakeetV3, .recommended)]
        case "ar":
            [Suggestion(whisperLargeV3Turbo, .recommended), Suggestion(cohereTranscribe, .mostAccurate)]
        case "tr", "ms", "tl", "fa", "mk", "bn":
            [Suggestion(whisperLargeV3Turbo, .recommended)]
        case "vi":
            [Suggestion(cohereTranscribe, .mostAccurate)]
        case "bg", "cs", "de", "es", "et", "fr", "hr", "hu", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk",
            "sl", "uk":
            [Suggestion(parakeetV3, .recommended)]
        default:
            []
        }
    }
}

/// A language selection that a model cannot keep, described before the switch is applied.
struct TranscriptionLanguageChange: Equatable {
    let modelName: String
    let previousLanguages: [String]
    let resultingLanguages: [String]
    let unsupportedLanguages: [String]

    init?(selection: [String], model: any TranscriptionModel) {
        let previous = TranscriptionLanguageSupport.normalizedSelection(selection)
        let resulting = TranscriptionLanguageSupport.validLanguagesOrFallback(previous, for: model)
        guard resulting != previous else { return nil }

        let available = TranscriptionLanguageSupport.languages(for: model)
        modelName = model.displayName
        previousLanguages = previous
        resultingLanguages = resulting
        unsupportedLanguages = previous.filter { available[$0] == nil }
        resultingNames = TranscriptionLanguageSupport.displayNames(for: resulting, in: available)
    }

    private let resultingNames: String

    var title: String {
        String(format: String(localized: "Switch to %@?"), modelName)
    }

    var message: String {
        if unsupportedLanguages.isEmpty {
            return String(
                format: String(localized: "%1$@ transcribes one language at a time, so this mode's language changes to %2$@."),
                modelName, resultingNames)
        }
        if unsupportedLanguages == ["auto"] {
            return String(
                format: String(localized: "%1$@ can't detect the language automatically, so this mode's language changes to %2$@."),
                modelName, resultingNames)
        }
        return String(
            format: String(localized: "%1$@ doesn't support %2$@, so this mode's language changes to %3$@."),
            modelName, TranscriptionLanguageSupport.displayNames(for: unsupportedLanguages), resultingNames)
    }
}
