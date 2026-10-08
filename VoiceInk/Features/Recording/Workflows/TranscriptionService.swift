import Foundation

struct TranscriptionRequestContext {
    let languages: [String]
    let language: String?
    let prompt: String?

    init(languages: [String], model: (any TranscriptionModel)? = nil) {
        let selection = model.map { TranscriptionLanguageSupport.validLanguagesOrFallback(languages, for: $0) }
            ?? TranscriptionLanguageSupport.normalizedSelection(languages)
        self.languages = selection
        language = TranscriptionLanguageSupport.recognitionLanguage(for: selection)
        prompt = model == nil || model?.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: selection) : nil
    }

    static var currentDefaults: TranscriptionRequestContext {
        TranscriptionRequestContext(languages: UserDefaults.standard.selectedTranscriptionLanguages)
    }

    func scoped(to model: any TranscriptionModel) -> TranscriptionRequestContext {
        let selection = TranscriptionLanguageSupport.validLanguagesOrFallback(languages, for: model)
        let scopedPrompt = model.provider == .whisper
            ? (selection == languages ? prompt : WhisperPrompt.resolvedPrompt(for: selection)) : nil
        return TranscriptionRequestContext(languages: selection, prompt: scopedPrompt)
    }

    private init(languages: [String], prompt: String?) {
        self.languages = languages
        language = TranscriptionLanguageSupport.recognitionLanguage(for: languages)
        self.prompt = prompt
    }
}

/// A protocol defining the interface for a transcription service.
/// This allows for a unified way to handle both local and cloud-based transcription models.
protocol TranscriptionService {
    /// Transcribes the audio from a given file URL.
    ///
    /// - Parameters:
    ///   - audioURL: The URL of the audio file to transcribe.
    ///   - model: The `TranscriptionModel` to use for transcription. This provides context about the provider (local, OpenAI, etc.).
    /// - Returns: The transcribed text as a `String`.
    /// - Throws: An error if the transcription fails.
    func transcribe(audioURL: URL, model: any TranscriptionModel, context: TranscriptionRequestContext) async throws
        -> String
}

extension TranscriptionService {
    func transcribe(audioURL: URL, model: any TranscriptionModel) async throws -> String {
        let context = TranscriptionRequestContext.currentDefaults.scoped(to: model)
        return try await transcribe(audioURL: audioURL, model: model, context: context)
    }
}
