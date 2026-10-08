import Foundation
import Testing
@testable import VoiceInk

struct TranscriptionLanguageTests {
    private let whisper = ImportedWhisperModel(fileBaseName: "ggml-small")

    @Test func legacyLanguagePreferenceIsPreservedAndSavedAsAnArray() throws {
        let suite = "TranscriptionLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("es", forKey: "SelectedLanguage")

        let migrated = defaults.selectedTranscriptionLanguages
        defaults.selectedTranscriptionLanguages = migrated + ["en", "es", ""]

        #expect(migrated == ["es"])
        #expect(defaults.stringArray(forKey: "SelectedLanguages") == ["es", "en"])
        #expect(defaults.string(forKey: "SelectedLanguage") == "auto")
        #expect(defaults.selectedTranscriptionLanguages == ["es", "en"])
    }

    @Test func emptyPreferencesFallBackToEnglish() throws {
        let suite = "TranscriptionLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.selectedTranscriptionLanguages == ["en"])
        defaults.selectedTranscriptionLanguages = []

        #expect(defaults.selectedTranscriptionLanguages == ["en"])
        #expect(defaults.string(forKey: "SelectedLanguage") == "en")
    }

    @Test func autoDetectionExcludesExplicitLanguages() {
        let automatic = TranscriptionLanguageSupport.settingLanguage("auto", isSelected: true, in: ["es", "en"])
        let explicit = TranscriptionLanguageSupport.settingLanguage("es", isSelected: true, in: automatic)

        #expect(automatic == ["auto"])
        #expect(explicit == ["es"])
        #expect(TranscriptionLanguageSupport.normalizedSelection(["es", "auto", "en"]) == ["auto"])
    }

    @Test func selectionCannotLoseItsLastLanguage() {
        let remaining = TranscriptionLanguageSupport.settingLanguage("en", isSelected: false, in: ["es", "en"])
        let last = TranscriptionLanguageSupport.settingLanguage("es", isSelected: false, in: remaining)

        #expect(remaining == ["es"])
        #expect(last == ["es"])
    }

    @Test func bilingualWhisperRequestUsesAutomaticDetectionAndBothPrompts() {
        let context = TranscriptionRequestContext(languages: ["es", "en", "es"], model: whisper)

        #expect(context.languages == ["es", "en"])
        #expect(context.language == "auto")
        #expect(context.prompt == "¡Hola, ¿cómo estás? Encantado de conocerte. Hello, how are you doing? Nice to meet you.")
        #expect(context.scoped(to: whisper).prompt == context.prompt)
    }

    @Test func singleWhisperLanguageRemainsExplicit() {
        let context = TranscriptionRequestContext(languages: ["es"], model: whisper)

        #expect(context.language == "es")
        #expect(context.prompt == "¡Hola, ¿cómo estás? Encantado de conocerte.")
    }

    @Test func automaticDetectionHasNoLanguagePrompt() throws {
        let suite = "TranscriptionLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["auto": "Ignore this prompt"], forKey: "CustomLanguagePrompts")

        let prompt = WhisperPrompt.resolvedPrompt(for: ["auto"], defaults: defaults)
        let context = TranscriptionRequestContext(languages: ["auto"], model: whisper)

        #expect(prompt.isEmpty)
        #expect(context.language == "auto")
        #expect(context.prompt == "")
    }

    @Test func customPromptsAreCombinedInSelectionOrderWithoutDuplicates() throws {
        let suite = "TranscriptionLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["es": "Spanish vocabulary", "en": "English vocabulary"], forKey: "CustomLanguagePrompts")

        let prompt = WhisperPrompt.resolvedPrompt(for: ["es", "en", "es", "af"], defaults: defaults)

        #expect(prompt == "Spanish vocabulary English vocabulary")
    }

    @Test func unsupportedLanguagesAreRemovedBeforePromptResolution() {
        let context = TranscriptionRequestContext(languages: ["en-US", "es"], model: whisper)

        #expect(context.languages == ["es"])
        #expect(context.language == "es")
        #expect(context.prompt == "¡Hola, ¿cómo estás? Encantado de conocerte.")
    }

    @Test func englishOnlyWhisperDoesNotReceiveOtherLanguagePrompts() {
        let englishOnly = WhisperModel(
            name: "ggml-small.en", displayName: "Small English", size: "", supportedLanguages: ["en": "English"],
            description: "", speed: 0, accuracy: 0, ramUsage: 0
        )
        let context = TranscriptionRequestContext(languages: ["es", "en"]).scoped(to: englishOnly)

        #expect(!TranscriptionLanguageSupport.supportsMultipleSelection(for: englishOnly))
        #expect(context.languages == ["en"])
        #expect(context.language == "en")
        #expect(context.prompt == "Hello, how are you doing? Nice to meet you.")
    }

    @Test func otherProvidersKeepOneLanguageAndNoWhisperPrompt() {
        let cloud = CloudModel(
            name: "cloud", displayName: "Cloud", description: "", provider: .groq, isMultilingual: true,
            supportedLanguages: ["auto": "Auto-detect", "en": "English", "es": "Spanish"]
        )
        let context = TranscriptionRequestContext(languages: ["es", "en"]).scoped(to: cloud)
        let apple = NativeAppleModel(
            name: "apple", displayName: "Apple", description: "", isMultilingualModel: true,
            supportedLanguages: ["en-US": "English", "es-ES": "Spanish"]
        )
        let appleContext = TranscriptionRequestContext(languages: ["es", "en"]).scoped(to: apple)

        #expect(!TranscriptionLanguageSupport.supportsMultipleSelection(for: cloud))
        #expect(context.language == "es")
        #expect(context.prompt == nil)
        #expect(!TranscriptionLanguageSupport.supportsMultipleSelection(for: apple))
        #expect(appleContext.language == "en-US")
        #expect(appleContext.prompt == nil)
    }

    @Test func legacyModesDecodeTheirSingleLanguage() throws {
        let data = Data("""
            {"id":"7BD34D21-6D2E-422D-A319-48BB33769C8B","name":"Spanish",
             "isAIEnhancementEnabled":false,"selectedLanguage":"es"}
            """.utf8)

        let mode = try JSONDecoder().decode(ModeConfig.self, from: data)

        #expect(mode.transcriptionLanguages == ["es"])
        #expect(mode.selectedLanguages == nil)
    }

    @Test @MainActor func modeLanguagesSurviveEditingAndPersistence() throws {
        let mode = ModeConfig(name: "Bilingual", isAIEnhancementEnabled: false, selectedLanguages: ["es", "en"])
        var draft = ModeConfigDraft(mode: .edit(mode), modeManager: .shared)

        draft.useCompatibleLanguage(for: whisper)
        let saved = draft.makeConfig(mode: .edit(mode))
        let decoded = try JSONDecoder().decode(ModeConfig.self, from: JSONEncoder().encode(saved))

        #expect(decoded.transcriptionLanguages == ["es", "en"])
        #expect(decoded.selectedLanguage == "auto")
        #expect(draft.transcriptionLanguages == ["es", "en"])
    }

    @Test @MainActor func runtimeUsesModeLanguagesInsteadOfGlobalDefaults() throws {
        let mode = ModeConfig(
            name: "Bilingual", isAIEnhancementEnabled: false, selectedTranscriptionModelName: whisper.name,
            selectedLanguages: ["es", "en"]
        )

        let configuration = try #require(ModeRuntimeResolver.transcriptionConfiguration(from: .available(mode: mode, model: whisper)))
        let context = configuration.requestContext.scoped(to: whisper)

        #expect(context.languages == ["es", "en"])
        #expect(context.language == "auto")
        #expect(context.prompt == "¡Hola, ¿cómo estás? Encantado de conocerte. Hello, how are you doing? Nice to meet you.")
    }
}
