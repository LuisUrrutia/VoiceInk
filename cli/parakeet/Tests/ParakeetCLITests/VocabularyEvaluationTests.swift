import Foundation
import XCTest
@testable import ParakeetCLI

final class VocabularyEvaluationTests: XCTestCase {
    func testTermMatcherCountsWholeTermsIgnoringCaseAndAccents() {
        XCTAssertEqual(TermMatcher.occurrences(of: "VoiceInk", in: "voiceink, VoiceInk. VoiceInks VoiceInk"), 3)
        XCTAssertEqual(TermMatcher.occurrences(of: "Voice Inc", in: "Uso Voice Inc. y voice inc"), 2)
        XCTAssertEqual(TermMatcher.occurrences(of: "PR", in: "PRs y un PR"), 1)
        XCTAssertEqual(TermMatcher.occurrences(of: "Cafe", in: "un café"), 1)
        XCTAssertEqual(TermMatcher.occurrences(of: ".env", in: "edita el .env ahora"), 1)
    }

    func testScoreCountsExpectedHitsAndUnexpectedInsertions() {
        let score = TermScore.score(
            plain: "Abrí Voice Inc y el orca", boosted: "Abrí VoiceInk y el Orca",
            expected: ["VoiceInk"], vocabulary: ["VoiceInk", "Orca", "Zod"]
        )

        XCTAssertEqual(score, TermScore(expected: 1, plainHits: 0, boostedHits: 1, unexpectedInsertions: 0))

        let control = TermScore.score(plain: "Dame un rato", boosted: "Dame un Roy", expected: [], vocabulary: ["Roy"])
        XCTAssertEqual(control, TermScore(expected: 0, plainHits: 0, boostedHits: 0, unexpectedInsertions: 1))
    }

    func testRepeatedExpectedTermsAreCountedPerMention() {
        let score = TermScore.score(plain: "VoiceInk", boosted: "VoiceInk y VoiceInk",
                                    expected: ["VoiceInk", "voiceink"], vocabulary: ["VoiceInk"])

        XCTAssertEqual(score, TermScore(expected: 2, plainHits: 1, boostedHits: 2, unexpectedInsertions: 0))
    }

    func testManifestParsesTermsControlsReferencesAndRelativePaths() throws {
        let directory = URL(fileURLWithPath: "/tmp/eval")
        let samples = try EvaluationManifest.parse("""
        file\texpected_terms\treference
        # comment
        terms/01.wav\tVoiceInk; Worktrunk\tAbrí VoiceInk en Worktrunk.
        control/01.wav\t\tHoy hace sol.
        /abs/02.wav
        """, relativeTo: directory)

        XCTAssertEqual(samples, [
            EvaluationSample(audio: directory.appendingPathComponent("terms/01.wav"), expectedTerms: ["VoiceInk", "Worktrunk"],
                             reference: "Abrí VoiceInk en Worktrunk."),
            EvaluationSample(audio: directory.appendingPathComponent("control/01.wav"), expectedTerms: [], reference: "Hoy hace sol."),
            EvaluationSample(audio: URL(fileURLWithPath: "/abs/02.wav"), expectedTerms: [], reference: ""),
        ])
    }

    func testOptionsDefaultToConservativeSettingsAndAcceptOverrides() throws {
        let defaults = try EvaluationOptions.parse(["--manifest", "m.tsv", "--term", "VoiceInk=Voice Inc, Voice Ink"])
        XCTAssertEqual(defaults.settings, .conservative)
        XCTAssertEqual(defaults.model, "ultra")
        XCTAssertEqual(defaults.terms, [VocabularyBoostTerm(text: "VoiceInk", aliases: ["Voice Inc", "Voice Ink"])])

        let tuned = try EvaluationOptions.parse([
            "--manifest", "m.tsv", "--dictionary", "d.json", "--cbw", "1.5", "--min-similarity", "0.6",
            "--min-term-length", "4", "--max-terms", "10", "--margin", "0.1", "--acoustic-rescue", "--runs", "3",
        ])
        XCTAssertEqual(tuned.settings, VocabularyBoostSettings(contextBiasWeight: 1.5, minimumSimilarity: 0.6, minimumTermLength: 4,
                                                               maximumTerms: 10, marginSeconds: 0.1, acousticRescue: true))
        XCTAssertEqual(tuned.runs, 3)

        XCTAssertThrowsError(try EvaluationOptions.parse(["--manifest", "m.tsv"]))
        XCTAssertThrowsError(try EvaluationOptions.parse(["--manifest", "m.tsv", "--term", "X", "--model", "v4"]))
        XCTAssertThrowsError(try EvaluationOptions.parse(["--manifest", "m.tsv", "--term", "X", "--runs", "0"]))
    }

    func testDictionaryExportTermsMatchTheAppMapping() throws {
        let data = Data("""
        {"format":"voiceink.dictionary","schemaVersion":2,
         "vocabulary":[{"term":"Zod"},{"term":"VoiceInk"},{"term":"wt"}],
         "replacements":[{"sources":["Voice Inc","Voice Ink"],"replacement":"VoiceInk"},{"sources":["zed"],"replacement":"Zed"}]}
        """.utf8)
        let archive = try JSONDecoder().decode(EvaluationDictionary.Archive.self, from: data)

        let terms = EvaluationDictionary.terms(archive: archive, extra: [VocabularyBoostTerm(text: "Claude", aliases: ["Cloud"])],
                                               settings: .conservative)

        XCTAssertEqual(terms, [
            VocabularyBoostTerm(text: "VoiceInk", aliases: ["Voice Inc", "Voice Ink"]),
            VocabularyBoostTerm(text: "Zod", aliases: []),
            VocabularyBoostTerm(text: "Claude", aliases: ["Cloud"]),
        ])
    }
}
