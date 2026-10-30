import FluidAudio
import Foundation
import SwiftData
import XCTest
@testable import VoiceInk

final class ParakeetVocabularyBoostTests: XCTestCase {
    private let timings = [TokenTiming(token: " Voice", tokenId: 1, startTime: 0, endTime: 0.4, confidence: 0.9)]
    private let audio: [Float] = [0.1, 0.2, 0.3]

    func testTermsKeepVocabularyOrderAndSkipDuplicatesAndShortTerms() {
        let terms = VocabularyBoostTerms.make(
            vocabulary: ["VoiceInk", " voiceink ", "PR", "wt", "  ", "Zod", "Café"], replacements: []
        )

        XCTAssertEqual(terms, [
            VocabularyBoostTerm(text: "VoiceInk", aliases: []),
            VocabularyBoostTerm(text: "Zod", aliases: []),
            VocabularyBoostTerm(text: "Café", aliases: []),
        ])
    }

    func testReplacementSourcesTargetingAVocabularyTermBecomeItsAliases() {
        let terms = VocabularyBoostTerms.make(
            vocabulary: ["VoiceInk", "Worktrunk"],
            replacements: [
                VocabularyBoostReplacementRule(sources: ["Voice Inc", "Voice Ink"], replacement: "VoiceInk"),
                VocabularyBoostReplacementRule(sources: ["voice inc", "voiceink"], replacement: " voiceink "),
                VocabularyBoostReplacementRule(sources: ["Work trunk"], replacement: "Worktree"),
            ]
        )

        XCTAssertEqual(terms, [
            VocabularyBoostTerm(text: "VoiceInk", aliases: ["Voice Inc", "Voice Ink"]),
            VocabularyBoostTerm(text: "Worktrunk", aliases: []),
        ])
    }

    func testTermLimitKeepsTheFirstTerms() {
        var settings = VocabularyBoostSettings.conservative
        settings.maximumTerms = 2

        let terms = VocabularyBoostTerms.make(vocabulary: ["Alpha", "Bravo", "Charlie"], replacements: [], settings: settings)

        XCTAssertEqual(terms.map(\.text), ["Alpha", "Bravo"])
    }

    @MainActor
    func testDictionaryTermsReadVocabularyAndReplacementVariants() throws {
        let schema = Schema([VocabularyWord.self, VocabularySection.self, WordReplacement.self])
        let container = try ModelContainer(
            for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        context.insert(VocabularyWord(word: "Zod"))
        context.insert(VocabularyWord(word: "VoiceInk"))
        context.insert(WordReplacement(originalText: "Voice Inc, Voice Ink", replacementText: "VoiceInk"))
        try context.save()

        let terms = ParakeetVocabularyBoost.dictionaryTerms(in: context)

        XCTAssertEqual(terms, [
            VocabularyBoostTerm(text: "VoiceInk", aliases: ["Voice Inc", "Voice Ink"]),
            VocabularyBoostTerm(text: "Zod", aliases: []),
        ])
    }

    func testPreferenceDefaultsOffAndRoundTripsThroughConfiguration() throws {
        let suite = "ParakeetVocabularyBoostTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ParakeetVocabularyBoost.enabledKey
        XCTAssertFalse(defaults.bool(forKey: key))

        defaults.set(true, forKey: key)
        let captured = try ConfigurationPreferences.capture(from: defaults)
        defaults.set(false, forKey: key)
        try ConfigurationPreferences.apply([key: try XCTUnwrap(captured[key])], to: defaults)

        XCTAssertEqual(captured[key], .bool(true))
        XCTAssertTrue(defaults.bool(forKey: key))
        XCTAssertThrowsError(try ConfigurationPreferences.validate([key: .string("yes")]))
    }

    func testDisabledBoostKeepsTextWithoutReadingTermsOrRescoring() async throws {
        let rescorer = RescorerFixture(result: .success(VocabularyBoostResult(text: "VoiceInk", replacements: [])))
        let boost = ParakeetVocabularyBoost(isEnabled: { false }, terms: { XCTFail("Terms read"); return [] }, rescorer: rescorer)

        let text = try await boost.apply(to: "Voice Inc", tokenTimings: timings, audioSamples: audio)
        let calls = await rescorer.calls
        let releases = await rescorer.releases

        XCTAssertEqual(text, "Voice Inc")
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(releases, 1)
    }

    func testEnabledBoostRescoresTheDecodedAudioAndTimings() async throws {
        let rescorer = RescorerFixture(result: .success(VocabularyBoostResult(
            text: "VoiceInk", replacements: [VocabularyBoostReplacement(original: "Voice Inc", replacement: "VoiceInk")]
        )))
        let boost = ParakeetVocabularyBoost(
            isEnabled: { true }, terms: { [VocabularyBoostTerm(text: "VoiceInk", aliases: ["Voice Inc"])] }, rescorer: rescorer
        )

        let text = try await boost.apply(to: "Voice Inc", tokenTimings: timings, audioSamples: audio)
        let request = await rescorer.lastRequest

        XCTAssertEqual(text, "VoiceInk")
        XCTAssertEqual(request?.text, "Voice Inc")
        XCTAssertEqual(request?.audio, audio)
        XCTAssertEqual(request?.timingCount, 1)
        XCTAssertEqual(request?.terms.map(\.text), ["VoiceInk"])
        XCTAssertEqual(request?.settings, .conservative)
    }

    func testEmptyVocabularyOrMissingTimingsSkipRescoring() async throws {
        let rescorer = RescorerFixture(result: .success(VocabularyBoostResult(text: "changed", replacements: [])))
        let empty = ParakeetVocabularyBoost(isEnabled: { true }, terms: { [] }, rescorer: rescorer)
        let untimed = ParakeetVocabularyBoost(
            isEnabled: { true }, terms: { [VocabularyBoostTerm(text: "VoiceInk", aliases: [])] }, rescorer: rescorer
        )

        let first = try await empty.apply(to: "Voice Inc", tokenTimings: timings, audioSamples: audio)
        let second = try await untimed.apply(to: "Voice Inc", tokenTimings: nil, audioSamples: audio)
        let calls = await rescorer.calls

        XCTAssertEqual([first, second], ["Voice Inc", "Voice Inc"])
        XCTAssertEqual(calls, 0)
    }

    func testMissingCTCModelFallsBackToUnboostedText() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MissingCTC-\(UUID())")
        let boost = ParakeetVocabularyBoost(
            isEnabled: { true }, terms: { [VocabularyBoostTerm(text: "VoiceInk", aliases: [])] },
            rescorer: FluidAudioVocabularyBooster(directory: directory)
        )

        await boost.prepare()
        let text = try await boost.apply(to: "Voice Inc", tokenTimings: timings, audioSamples: audio)

        XCTAssertEqual(text, "Voice Inc")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testRescoringFailuresFallBackToUnboostedText() async throws {
        for error in [NSError(domain: "CTC", code: 1) as Error, CancellationError()] {
            let boost = ParakeetVocabularyBoost(
                isEnabled: { true }, terms: { [VocabularyBoostTerm(text: "VoiceInk", aliases: [])] },
                rescorer: RescorerFixture(result: .failure(error))
            )

            let text = try await boost.apply(to: "Voice Inc", tokenTimings: timings, audioSamples: audio)

            XCTAssertEqual(text, "Voice Inc")
        }
    }

    @MainActor
    func testOptInInstalledModelsBoostTheAppTranscript() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let samplePath = environment["VOICEINK_VOCAB_SAMPLE"], let term = environment["VOICEINK_VOCAB_TERM"] else {
            throw XCTSkip("Set VOICEINK_VOCAB_SAMPLE (16 kHz WAV) and VOICEINK_VOCAB_TERM for the installed-model check")
        }
        guard AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .ultra), version: .ultra),
              ParakeetCTCModel.isInstalled() else {
            throw XCTSkip("Parakeet Ultra or the CTC vocabulary model is not installed")
        }
        let model = try XCTUnwrap(TranscriptionModelRegistry.models.first { $0.name == "parakeet-ultra" })
        let audio = URL(fileURLWithPath: samplePath)
        let context = TranscriptionRequestContext(languages: ["es"])
        let terms: @MainActor @Sendable () -> [VocabularyBoostTerm] = { [VocabularyBoostTerm(text: term, aliases: [])] }
        let plainService = FluidAudioTranscriptionService()
        let boostedService = FluidAudioTranscriptionService(
            vocabularyBoost: ParakeetVocabularyBoost(isEnabled: { true }, terms: terms)
        )

        let plain = try await plainService.transcribe(audioURL: audio, model: model, context: context)
        await boostedService.prepareVocabularyBoost(for: model)
        let boosted = try await boostedService.transcribe(audioURL: audio, model: model, context: context)
        await plainService.cleanup()
        await boostedService.cleanup()

        // Choose a sample whose plain transcript misspells the term.
        XCTAssertFalse(plain.contains(term), plain)
        XCTAssertTrue(boosted.contains(term), boosted)
    }

    func testOnlyBatchParakeetModelsSupportBoosting() {
        func model(_ name: String) -> FluidAudioModel {
            FluidAudioModel(name: name, displayName: name, description: "Fixture", size: "1 GB", speed: 1, accuracy: 1,
                            ramUsage: 1, supportedLanguages: ["en": "English"])
        }

        XCTAssertTrue(FluidAudioTranscriptionService.supportsVocabularyBoost(model("parakeet-tdt-0.6b-v2")))
        XCTAssertTrue(FluidAudioTranscriptionService.supportsVocabularyBoost(model("parakeet-tdt-0.6b-v3")))
        XCTAssertTrue(FluidAudioTranscriptionService.supportsVocabularyBoost(model("parakeet-ultra")))
        XCTAssertFalse(FluidAudioTranscriptionService.supportsVocabularyBoost(model("parakeet-unified-0.6b")))
        XCTAssertFalse(FluidAudioTranscriptionService.supportsVocabularyBoost(model("nemotron-multilingual-0.6b")))
    }
}

private actor RescorerFixture: VocabularyBoostRescoring {
    struct Request {
        let text: String
        let timingCount: Int
        let audio: [Float]
        let terms: [VocabularyBoostTerm]
        let settings: VocabularyBoostSettings
    }

    private let result: Result<VocabularyBoostResult, Error>
    private(set) var calls = 0
    private(set) var releases = 0
    private(set) var lastRequest: Request?

    init(result: Result<VocabularyBoostResult, Error>) {
        self.result = result
    }

    func prepare() async throws {}

    func rescore(
        text: String, tokenTimings: [TokenTiming], audioSamples: [Float],
        terms: [VocabularyBoostTerm], settings: VocabularyBoostSettings
    ) async throws -> VocabularyBoostResult {
        calls += 1
        lastRequest = Request(text: text, timingCount: tokenTimings.count, audio: audioSamples, terms: terms, settings: settings)
        return try result.get()
    }

    func release() {
        releases += 1
    }
}
