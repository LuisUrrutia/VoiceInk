import AVFoundation
import Foundation
import Testing
@testable import VoiceInk

struct WhisperPromptEchoTests {
    private let english = WhisperPrompt.resolvedPrompt(for: "en")

    @Test func promptKeepsTheFormatSentToWhisper() {
        #expect(WhisperPromptEcho(languagePrompt: english, hints: ["T3 Code", "Ottobit"]).prompt
            == "Hello, how are you doing? Nice to meet you.\nT3 Code, Ottobit")
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: ["T3 Code"]).prompt == "T3 Code")
        #expect(WhisperPromptEcho(languagePrompt: english, hints: []).prompt == english)
        #expect(WhisperPromptEcho(languagePrompt: "", hints: []).prompt == "")
    }

    @Test func hintsEchoIsDroppedAfterNormalization() {
        let echo = WhisperPromptEcho(languagePrompt: nil, hints: ["T3 Code", "Ottobit"])

        #expect(echo.removingEcho(from: [" T3 Code, Ottobit."]) == [])
        #expect(echo.removingEcho(from: ["t3   code;OTTOBIT!"]) == [])
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: ["Route 3", "Ottobit"])
            .removingEcho(from: [" Route three, Ottobit"]) == [])
        #expect(echo.removingEcho(from: ["Ｔ３ Ｃｏｄｅ， Ｏｔｔｏｂｉｔ。"]) == [])
    }

    @Test func wholePromptEchoIsDroppedEvenAcrossSegments() {
        let echo = WhisperPromptEcho(languagePrompt: english, hints: ["Ottobit"])

        #expect(echo.removingEcho(from: [" Hello, how are you doing? Nice to meet you. Ottobit."]) == [])
        #expect(echo.removingEcho(from: [" Hello, how are you doing?", " Nice to meet you.", " Ottobit."]) == [])
    }

    @Test func dictatingOneVocabularyWordIsKept() {
        let single = WhisperPromptEcho(languagePrompt: english, hints: ["Ottobit"])
        let several = WhisperPromptEcho(languagePrompt: english, hints: ["T3 Code", "Ottobit", "Kubernetes"])

        #expect(single.removingEcho(from: [" Ottobit."]) == [" Ottobit."])
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: ["Ottobit"]).removingEcho(from: ["Ottobit"]) == ["Ottobit"])
        #expect(several.removingEcho(from: [" Ottobit."]) == [" Ottobit."])
        #expect(several.removingEcho(from: [" T3 Code, Ottobit."]) == [" T3 Code, Ottobit."])
    }

    @Test func dictatingTheLanguageSampleSentenceIsKept() {
        // ggml-base returns exactly this sentence for `say` speech of it under the English prompt.
        let sentence = " Hello, how are you doing? Nice to meet you."

        #expect(WhisperPromptEcho(languagePrompt: english, hints: []).removingEcho(from: [sentence]) == [sentence])
        #expect(WhisperPromptEcho(languagePrompt: english, hints: ["T3 Code", "Ottobit"])
            .removingEcho(from: [sentence]) == [sentence])
    }

    @Test func speechContainingThePromptIsKept() {
        let echo = WhisperPromptEcho(languagePrompt: english, hints: ["T3 Code", "Ottobit"])
        let hints = WhisperPromptEcho(languagePrompt: nil, hints: ["T3 Code", "Ottobit"])

        #expect(hints.removingEcho(from: [" We shipped T3 Code and Ottobit today."])
            == [" We shipped T3 Code and Ottobit today."])
        #expect(hints.removingEcho(from: [" T3 Code, Ottobit. Let's ship it."]) == [" T3 Code, Ottobit. Let's ship it."])
        #expect(echo.removingEcho(from: [" Hello, how are you doing? Nice to meet you. T3 Code, Ottobit. Ship it."])
            == [" Hello, how are you doing? Nice to meet you. T3 Code, Ottobit. Ship it."])
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: ["note", "book"]).removingEcho(from: [" Notebook."])
            == [" Notebook."])
    }

    @Test func onlyTheEchoSegmentIsRemovedFromRealSpeech() {
        let echo = WhisperPromptEcho(languagePrompt: english, hints: ["T3 Code", "Ottobit"])

        #expect(echo.removingEcho(from: [" Let's ship it.", " T3 Code, Ottobit."]) == [" Let's ship it."])
        #expect(echo.removingEcho(from: [" T3 Code, Ottobit.", " Let's ship it."]) == [" Let's ship it."])
        #expect(echo.removingEcho(from: [" Let's ship it.", " Hello, how are you doing? Nice to meet you. T3 Code, Ottobit."])
            == [" Let's ship it."])
    }

    @Test func promptsInSeveralLanguagesAreMatched() {
        let spanish = WhisperPromptEcho(languagePrompt: WhisperPrompt.resolvedPrompt(for: "es"), hints: ["Ottobit"])
        let japanese = WhisperPromptEcho(languagePrompt: WhisperPrompt.resolvedPrompt(for: "ja"), hints: ["東京", "大阪"])
        let chinese = WhisperPromptEcho(languagePrompt: nil, hints: ["你好", "再见"])
        let arabic = WhisperPromptEcho(languagePrompt: nil, hints: ["مرحبا", "شكرا"])
        let german = WhisperPromptEcho(languagePrompt: nil, hints: ["Äpfel", "Straße"])
        let bilingual = WhisperPromptEcho(
            languagePrompt: WhisperPrompt.resolvedPrompt(for: ["es", "en"]), hints: ["Ottobit"]
        )

        #expect(spanish.removingEcho(from: [" Hola, cómo estás? Encantado de conocerte. Ottobit"]) == [])
        #expect(japanese.removingEcho(from: ["こんにちは、お元気ですか?お会いできて嬉しいです。東京、大阪"]) == [])
        #expect(japanese.removingEcho(from: ["東京、大阪。"]) == [])
        #expect(japanese.removingEcho(from: ["東京"]) == ["東京"])
        #expect(chinese.removingEcho(from: ["你好,再见。"]) == [])
        #expect(chinese.removingEcho(from: ["你好,再见,明天见。"]) == ["你好,再见,明天见。"])
        #expect(arabic.removingEcho(from: ["مرحبا، شكرا."]) == [])
        #expect(german.removingEcho(from: [" ÄPFEL, straße."]) == [])
        #expect(bilingual.removingEcho(from: [
            " ¡Hola, ¿cómo estás? Encantado de conocerte.", " Hello, how are you doing? Nice to meet you.", " Ottobit.",
        ]) == [])
        #expect(bilingual.removingEcho(from: [" ¡Hola, ¿cómo estás? Encantado de conocerte."])
            == [" ¡Hola, ¿cómo estás? Encantado de conocerte."])
    }

    @Test func anEmptyPromptDropsNothing() {
        let echo = WhisperPromptEcho(languagePrompt: nil, hints: [])
        let blank = WhisperPromptEcho(languagePrompt: "", hints: [])

        #expect(echo.removingEcho(from: []) == [])
        #expect(echo.removingEcho(from: [""]) == [""])
        #expect(blank.removingEcho(from: [" Hello."]) == [" Hello."])
    }

    @Test func groqDropsAnEchoOfTheHintsItSends() {
        let long = (0..<200).map { "Term\($0)" }
        let hints = GroqProvider.vocabularyHints(from: ["T3 Code", "", "Ottobit"])
        let echo = WhisperPromptEcho(languagePrompt: nil, hints: hints)

        #expect(echo.prompt == "T3 Code, Ottobit")
        #expect(echo.removingEcho(from: ["T3 Code, Ottobit."]) == [])
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: GroqProvider.vocabularyHints(from: ["Ottobit"]))
            .removingEcho(from: ["Ottobit."]) == ["Ottobit."])
        #expect(WhisperPromptEcho(languagePrompt: nil, hints: GroqProvider.vocabularyHints(from: long)).prompt.utf8.count <= 896)
    }

    @Test(arguments: ["parakeet-tdt-0.6b-v3", "cohere-transcribe", "sensevoice-small", "apple-speech"])
    func nonWhisperModelsReceiveNoPromptAndKeepHintText(modelName: String) throws {
        let model = try #require(TranscriptionModelRegistry.models.first { $0.name == modelName })
        let vocabulary = RecordingVocabulary(savedTerms: ["T3 Code", "Ottobit"])

        let context = TranscriptionRequestContext(languages: ["en"], model: model)
            .withVocabulary(vocabulary).scoped(to: model)

        #expect(model.provider != .whisper)
        #expect(context.prompt == nil)
        #expect(TranscriptionOutputFilter.filter(" T3 Code, Ottobit.") == "T3 Code, Ottobit.")
    }
}

/// Opt-in: `VOICEINK_WHISPER_MODEL=<ggml model path>` runs real whisper.cpp through the app's request path.
struct WhisperPromptEchoIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOICEINK_WHISPER_MODEL"] != nil))
    func installedWhisperModelKeepsDictationAndDropsTheTermList() async throws {
        let modelPath = try #require(ProcessInfo.processInfo.environment["VOICEINK_WHISPER_MODEL"])
        let previousVAD = UserDefaults.standard.object(forKey: "IsVADEnabled")
        UserDefaults.standard.set(false, forKey: "IsVADEnabled")
        defer { UserDefaults.standard.set(previousVAD, forKey: "IsVADEnabled") }
        let context = try await WhisperContext.createContext(path: modelPath)
        let english = TranscriptionRequestContext(languages: ["en"])
        let request = english.withVocabulary(RecordingVocabulary(savedTerms: ["T3 Code", "Ottobit", "Kubernetes"]))

        let sentence = try await context.transcribe(samples: speech("Hello, how are you doing? Nice to meet you."), request: english)
        let word = try await context.transcribe(samples: speech("Ottobit"), request: request)
        let termList = try await context.transcribe(
            samples: speech("Monday, Tuesday."),
            request: english.withVocabulary(RecordingVocabulary(savedTerms: ["Monday", "Tuesday"]))
        )
        await context.releaseResources()

        #expect(sentence.contains("Nice to meet you"))
        #expect(word.contains("Ottobit"))
        #expect(termList.isEmpty)
    }

    private func speech(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-echo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
