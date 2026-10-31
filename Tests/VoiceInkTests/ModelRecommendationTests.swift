import Foundation
import Testing
@testable import VoiceInk

struct ModelRecommendationTests {
    /// Hex's language list, with Filipino as Whisper's `tl`.
    private static let hexLanguages = [
        "auto", "en", "zh", "yue", "ja", "ko", "es", "fr", "de", "pt", "it", "ar", "hi", "bn", "vi", "ru", "uk", "nl",
        "pl", "tr", "sv", "da", "fi", "cs", "el", "ro", "hu", "id", "ms", "th", "fa", "bg", "hr", "et", "lv", "lt", "mt",
        "sk", "sl", "mk", "tl",
    ]

    private let catalog = TranscriptionModelRegistry.models

    private func suggestions(for languages: [String]) -> [String: ModelRecommendationRole] {
        let recommendations = ModelRecommendations(languages: languages)
        return catalog.reduce(into: [:]) { result, model in
            result[model.name] = recommendations.role(for: model)
        }
    }

    @Test(arguments: hexLanguages)
    func everySuggestionIsAShippedModelThatSupportsTheLanguage(language: String) {
        let recommendations = ModelRecommendations(languages: [language])
        let suggested = catalog.filter { recommendations.rank(of: $0) != nil }

        for model in suggested {
            #expect(TranscriptionLanguageSupport.languages(for: model)[language] != nil, "\(model.name) for \(language)")
            #expect(TranscriptionLanguageChange(selection: [language], model: model) == nil)
        }
        #expect(Set(suggested.map(\.provider)).isSubset(of: [.whisper, .fluidAudio, .transcribeCpp]))
    }

    @Test func hexExamplesMapToTheModelsVoiceInkShips() {
        #expect(suggestions(for: ["el"]) == [ModelRecommendations.cohereTranscribe: .recommended])
        #expect(suggestions(for: ["mt"]) == [ModelRecommendations.parakeetV3: .recommended])
        #expect(
            suggestions(for: ["ja"]) == [
                ModelRecommendations.whisperLargeV3Turbo: .recommended, ModelRecommendations.senseVoiceSmall: .fastest,
            ])
        #expect(
            suggestions(for: ["ar"]) == [
                ModelRecommendations.whisperLargeV3Turbo: .recommended, ModelRecommendations.cohereTranscribe: .mostAccurate,
            ])
        #expect(
            suggestions(for: ["sv"]) == [
                ModelRecommendations.whisperLargeV3Turbo: .recommended, ModelRecommendations.parakeetV3: .fastest,
            ])
        for language in ["tr", "fi", "fa", "mk", "ms", "tl"] {
            #expect(suggestions(for: [language])[ModelRecommendations.whisperLargeV3Turbo] == .recommended)
        }
        #expect(
            suggestions(for: ["en"]) == [
                ModelRecommendations.parakeetUnified: .recommended, ModelRecommendations.cohereTranscribe: .mostAccurate,
            ])
    }

    @Test func languagesWhoseHexRecommendationIsQwenGetNoSubstitute() {
        for language in ["yue", "ko", "hi", "id", "th"] {
            #expect(ModelRecommendations(languages: [language]).isEmpty, "\(language)")
        }
        #expect(suggestions(for: ["zh"]) == [ModelRecommendations.senseVoiceSmall: .fastest])
        #expect(suggestions(for: ["vi"]) == [ModelRecommendations.cohereTranscribe: .mostAccurate])
    }

    @Test func languagesWithoutHexEvidenceHaveNoRecommendations() {
        #expect(ModelRecommendations(languages: ["sw"]).isEmpty)
        #expect(ModelRecommendations(languages: ["no"]).isEmpty)
    }

    @Test func multipleLanguagesFollowAutomaticDetectionAndRequireMultipleSelection() {
        let bilingual = suggestions(for: ["es", "en"])

        #expect(bilingual == [ModelRecommendations.whisperLargeV3Turbo: .recommended])
        #expect(suggestions(for: ["auto"]) == bilingual)
        #expect(
            ModelRecommendations(languages: ["es", "en"]).languageDescription
                == ListFormatter.localizedString(byJoining: ["Spanish", "English"]))
    }

    @Test func filipinoAndAutomaticDetectionMatchHexEntries() {
        #expect(suggestions(for: ["fil"]) == [ModelRecommendations.whisperLargeV3Turbo: .recommended])
        #expect(
            ModelRecommendations(languages: ["auto"]).languageDescription
                == String(localized: "automatic language detection"))
    }

    @Test func localeSelectionsMatchTheirLanguage() {
        let parakeet = FluidAudioModel(
            name: ModelRecommendations.parakeetV3, displayName: "Parakeet V3", description: "Speech", size: "494 MB",
            speed: 0.99, accuracy: 0.94, ramUsage: 0.8, supportedLanguages: ["es": "Spanish", "en": "English"])

        #expect(ModelRecommendations(languages: ["es-ES"]).role(for: parakeet) == .recommended)
    }

    @Test func modelsWithAReusedNameOrMissingLanguageAreNotSuggested() {
        let custom = CustomCloudModel(
            name: ModelRecommendations.cohereTranscribe, displayName: "Custom", description: "Speech",
            apiEndpoint: "https://example.com/transcriptions", modelName: "custom")
        let englishOnlyParakeet = FluidAudioModel(
            name: ModelRecommendations.parakeetV3, displayName: "Parakeet", description: "Speech", size: "494 MB",
            speed: 0.99, accuracy: 0.94, ramUsage: 0.8, supportedLanguages: ["en": "English"])

        #expect(ModelRecommendations(languages: ["el"]).role(for: custom) == nil)
        #expect(ModelRecommendations(languages: ["es"]).role(for: englishOnlyParakeet) == nil)
    }
}
