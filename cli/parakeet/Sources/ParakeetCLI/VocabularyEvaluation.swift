import FluidAudio
import Foundation
import TranscriptionText

struct EvaluationOptions {
    static let usage = """
    Usage: voiceink-vocab-eval --manifest FILE [options]
      --manifest PATH               TSV rows: file, expected terms (;-separated, repeat for
                                    repeated mentions, empty for controls), optional reference.
                                    Relative audio paths resolve against the manifest folder.
      --dictionary PATH             VoiceInk Dictionary JSON export: terms, aliases, replacements
      --term TEXT[=ALIAS,ALIAS]     Additional boost term (repeatable)
      --model v2|v3|ultra           Installed Parakeet model (default: ultra)
      --model-directory PATH        Exact directory of compiled Parakeet files
      --ctc-directory PATH          Exact directory of the CTC 110M model
      --lang auto|CODE              Decoder script hint (default: auto)
      --no-vad                      Decode full audio instead of VAD speech
      --cbw N --min-similarity N --min-term-length N --max-terms N --margin N
      --acoustic-rescue             Enable FluidAudio's spotter-only rescue pass
      --runs N                      Rescore each file N times to expose nondeterminism (default: 1)
      --report PATH                 Write a JSON report with every transcript
      -h, --help                    Show usage
    Models are never downloaded. Settings default to the app's conservative values.
    """

    var manifest: URL?
    var dictionary: URL?
    var terms: [VocabularyBoostTerm] = []
    var model = "ultra"
    var modelDirectory: URL?
    var ctcDirectory: URL?
    var language: String?
    var noVAD = false
    var settings = VocabularyBoostSettings.conservative
    var runs = 1
    var report: URL?
    var help = false

    static func parse(_ arguments: [String]) throws -> EvaluationOptions {
        var options = EvaluationOptions()
        var index = 0
        func value(_ flag: String) throws -> String {
            index += 1
            guard index < arguments.count else { throw CLIError.message("Missing value for \(flag)") }
            return arguments[index]
        }
        func number<T: LosslessStringConvertible>(_ flag: String) throws -> T {
            let raw = try value(flag)
            guard let parsed = T(raw) else { throw CLIError.message("Invalid number for \(flag): \(raw)") }
            return parsed
        }
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help": options.help = true
            case "--manifest": options.manifest = URL(fileURLWithPath: try value(argument))
            case "--dictionary": options.dictionary = URL(fileURLWithPath: try value(argument))
            case "--term":
                let raw = try value(argument)
                let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
                let aliases = parts.count > 1 ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } : []
                options.terms.append(VocabularyBoostTerm(text: parts.first ?? "", aliases: aliases.filter { !$0.isEmpty }))
            case "--model": options.model = try value(argument)
            case "--model-directory": options.modelDirectory = URL(fileURLWithPath: try value(argument))
            case "--ctc-directory": options.ctcDirectory = URL(fileURLWithPath: try value(argument))
            case "--lang": options.language = try value(argument)
            case "--no-vad": options.noVAD = true
            case "--cbw": options.settings.contextBiasWeight = try number(argument)
            case "--min-similarity": options.settings.minimumSimilarity = try number(argument)
            case "--min-term-length": options.settings.minimumTermLength = try number(argument)
            case "--max-terms": options.settings.maximumTerms = try number(argument)
            case "--margin": options.settings.marginSeconds = try number(argument)
            case "--acoustic-rescue": options.settings.acousticRescue = true
            case "--runs": options.runs = try number(argument)
            case "--report": options.report = URL(fileURLWithPath: try value(argument))
            default: throw CLIError.message("Unknown option: \(argument)")
            }
            index += 1
        }
        if options.help { return options }
        guard options.manifest != nil else { throw CLIError.message("Provide --manifest PATH") }
        guard ["v2", "v3", "ultra"].contains(options.model) else { throw CLIError.message("Model must be v2, v3 or ultra") }
        if let language = options.language, language != "auto", Language(rawValue: language) == nil {
            throw CLIError.message("Unsupported language: \(language)")
        }
        guard options.runs >= 1 else { throw CLIError.message("--runs must be at least 1") }
        guard options.dictionary != nil || !options.terms.isEmpty else {
            throw CLIError.message("Provide --dictionary PATH or at least one --term")
        }
        return options
    }
}

struct EvaluationSample: Equatable {
    let audio: URL
    let expectedTerms: [String]
    let reference: String
}

enum EvaluationManifest {
    static func parse(_ contents: String, relativeTo directory: URL) throws -> [EvaluationSample] {
        var samples: [EvaluationSample] = []
        for (number, line) in contents.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let columns = line.components(separatedBy: "\t")
            let file = columns[0].trimmingCharacters(in: .whitespaces)
            if samples.isEmpty, file.lowercased() == "file" { continue }
            guard !file.isEmpty else { throw CLIError.message("Manifest line \(number + 1) has no audio file") }
            let terms = columns.count > 1
                ? columns[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            let reference = columns.count > 2 ? columns[2].trimmingCharacters(in: .whitespaces) : ""
            let audio = file.hasPrefix("/") ? URL(fileURLWithPath: file) : directory.appendingPathComponent(file)
            samples.append(EvaluationSample(audio: audio, expectedTerms: terms, reference: reference))
        }
        guard !samples.isEmpty else { throw CLIError.message("Manifest lists no audio files") }
        return samples
    }
}

enum TermMatcher {
    /// Case- and diacritic-insensitive occurrences delimited by non-alphanumeric characters.
    static func occurrences(of term: String, in text: String) -> Int {
        let haystack = text as NSString
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searchRange = NSRange(location: 0, length: haystack.length)
        while true {
            let found = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            guard found.location != NSNotFound else { break }
            let before = found.location > 0 ? haystack.substring(with: NSRange(location: found.location - 1, length: 1)) : ""
            let afterLocation = found.location + found.length
            let after = afterLocation < haystack.length ? haystack.substring(with: NSRange(location: afterLocation, length: 1)) : ""
            if !isWordCharacter(before), !isWordCharacter(after) { count += 1 }
            searchRange = NSRange(location: found.location + max(found.length, 1), length: haystack.length - found.location - max(found.length, 1))
        }
        return count
    }

    private static func isWordCharacter(_ character: String) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

struct TermScore: Equatable {
    var expected = 0
    var plainHits = 0
    var boostedHits = 0
    /// Boost-term mentions in the boosted text beyond the plain text and the expected count.
    var unexpectedInsertions = 0

    static func score(plain: String, boosted: String, expected: [String], vocabulary: [String]) -> TermScore {
        var counts: [String: (term: String, count: Int)] = [:]
        for term in expected { counts[term.lowercased(), default: (term, 0)].count += 1 }
        var score = TermScore()
        for (term, count) in counts.values {
            score.expected += count
            score.plainHits += min(count, TermMatcher.occurrences(of: term, in: plain))
            score.boostedHits += min(count, TermMatcher.occurrences(of: term, in: boosted))
        }
        var seen = Set<String>()
        for term in vocabulary where seen.insert(term.lowercased()).inserted {
            let allowed = max(TermMatcher.occurrences(of: term, in: plain), counts[term.lowercased()]?.count ?? 0)
            score.unexpectedInsertions += max(0, TermMatcher.occurrences(of: term, in: boosted) - allowed)
        }
        return score
    }

    static func + (left: TermScore, right: TermScore) -> TermScore {
        TermScore(expected: left.expected + right.expected, plainHits: left.plainHits + right.plainHits,
                  boostedHits: left.boostedHits + right.boostedHits,
                  unexpectedInsertions: left.unexpectedInsertions + right.unexpectedInsertions)
    }
}

enum EvaluationDictionary {
    struct Archive: Decodable {
        struct Vocabulary: Decodable { let term: String }
        struct Replacement: Decodable {
            let sources: [String]
            let replacement: String
        }
        let format: String
        let schemaVersion: Int
        let vocabulary: [Vocabulary]?
        let replacements: [Replacement]
    }

    /// Dictionary terms in the app's order (sorted by word), followed by explicit terms.
    static func terms(archive: Archive?, extra: [VocabularyBoostTerm], settings: VocabularyBoostSettings) -> [VocabularyBoostTerm] {
        let words = (archive?.vocabulary ?? []).map(\.term).sorted() + extra.map(\.text)
        let rules = (archive?.replacements ?? []).map { VocabularyBoostReplacementRule(sources: $0.sources, replacement: $0.replacement) }
            + extra.map { VocabularyBoostReplacementRule(sources: $0.aliases, replacement: $0.text) }
        return VocabularyBoostTerms.make(vocabulary: words, replacements: rules, settings: settings)
    }

    static func load(_ url: URL) throws -> Archive {
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
        guard archive.format == "voiceink.dictionary", (1...2).contains(archive.schemaVersion) else {
            throw CLIError.message("Unsupported VoiceInk Dictionary export")
        }
        return archive
    }
}

private struct EvaluationRow: Encodable {
    let file: String
    let expectedTerms: [String]
    let reference: String
    let plain: String
    let boosted: String
    let plainFinal: String
    let boostedFinal: String
    let replacements: [String]
    let nondeterministic: Bool
    let audioSeconds: Double
    let asrSeconds: Double
    let rescoreSeconds: Double
}

public enum VocabularyEvaluationApplication {
    public static func run(arguments: [String], stdout: @escaping (String) -> Void,
                           stderr: @escaping (String) -> Void) async -> Int32 {
        let options: EvaluationOptions
        do {
            options = try EvaluationOptions.parse(arguments)
            if options.help { stdout(EvaluationOptions.usage); return 0 }
        } catch {
            stderr(error.localizedDescription)
            stderr(EvaluationOptions.usage)
            return 2
        }
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
        do {
            return try await evaluate(options, stdout: stdout, stderr: stderr)
        } catch {
            stderr(error.localizedDescription)
            return 1
        }
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = ContinuousClock.now - start
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func evaluate(_ options: EvaluationOptions, stdout: (String) -> Void,
                                 stderr: @escaping (String) -> Void) async throws -> Int32 {
        guard let manifestURL = options.manifest else { return 2 }
        let samples = try EvaluationManifest.parse(String(contentsOf: manifestURL, encoding: .utf8),
                                                   relativeTo: manifestURL.deletingLastPathComponent())
        let archive = try options.dictionary.map(EvaluationDictionary.load)
        let terms = EvaluationDictionary.terms(archive: archive, extra: options.terms, settings: options.settings)
        guard !terms.isEmpty else { throw CLIError.message("No boost terms remain after filtering") }

        var settings = Settings()
        settings.vadEnabled = !options.noVAD
        settings.language = options.language ?? "auto"
        if let dictionary = options.dictionary { settings.replacements = try Settings.dictionaryPlan(from: dictionary) }

        let transcriber = try await Transcriber(model: options.model, modelDirectory: options.modelDirectory,
                                                settings: settings, log: stderr)
        let ctcDirectory = options.ctcDirectory ?? ParakeetCTCModel.defaultDirectory
        var start = ContinuousClock.now
        let models = try await ParakeetCTCModel.load(from: ctcDirectory)
        let rescorer = try await ParakeetVocabularyRescorer(models: models, modelDirectory: ctcDirectory,
                                                            terms: terms, settings: options.settings)
        let setupSeconds = elapsed(since: start)
        stderr("Boost terms (\(terms.count)): " + terms.map { $0.aliases.isEmpty ? $0.text : "\($0.text) [\($0.aliases.joined(separator: ", "))]" }.joined(separator: "; "))

        var rows: [EvaluationRow] = []
        var termScore = TermScore()
        var finalScore = TermScore()
        var controlScore = TermScore()
        var failures = false
        for sample in samples {
            do {
                let audio = try await AudioDecoder.decode(sample.audio)
                start = ContinuousClock.now
                let decoded = try await transcriber.decode(audio)
                let asrSeconds = elapsed(since: start)
                let plain = decoded?.result.text ?? ""

                var outputs: [VocabularyBoostResult] = []
                var rescoreSeconds = 0.0
                for run in 0..<options.runs {
                    start = ContinuousClock.now
                    var output = VocabularyBoostResult(text: plain, replacements: [])
                    if let decoded {
                        output = try await rescorer.rescore(
                            text: plain, tokenTimings: decoded.result.tokenTimings ?? [], audioSamples: decoded.samples
                        )
                    }
                    if run == 0 { rescoreSeconds = elapsed(since: start) }
                    outputs.append(output)
                }
                let boosted = outputs[0].text
                let duration = Double(audio.count) / 16_000
                let plainFinal = decoded.map { transcriber.transcript(plain, decoded: $0, duration: duration).text } ?? ""
                let boostedFinal = decoded.map { transcriber.transcript(boosted, decoded: $0, duration: duration).text } ?? ""
                let vocabulary = terms.map(\.text)
                let raw = TermScore.score(plain: plain, boosted: boosted, expected: sample.expectedTerms, vocabulary: vocabulary)
                if sample.expectedTerms.isEmpty { controlScore = controlScore + raw } else { termScore = termScore + raw }
                finalScore = finalScore + TermScore.score(plain: plainFinal, boosted: boostedFinal,
                                                          expected: sample.expectedTerms, vocabulary: vocabulary)
                let row = EvaluationRow(
                    file: sample.audio.lastPathComponent, expectedTerms: sample.expectedTerms, reference: sample.reference,
                    plain: plain, boosted: boosted, plainFinal: plainFinal, boostedFinal: boostedFinal,
                    replacements: outputs[0].replacements.map { "\($0.original) -> \($0.replacement)" },
                    nondeterministic: Set(outputs.map(\.text)).count > 1,
                    audioSeconds: duration, asrSeconds: asrSeconds, rescoreSeconds: rescoreSeconds
                )
                rows.append(row)
                let marker = plain == boosted ? "same" : (sample.expectedTerms.isEmpty ? "CHANGED-CONTROL" : "changed")
                stdout("[\(marker)] \(row.file)\n  plain:   \(plain)\n  boosted: \(boosted)"
                       + (row.nondeterministic ? "\n  NONDETERMINISTIC across \(options.runs) runs" : ""))
            } catch {
                failures = true
                stderr("\(sample.audio.path): \(error.localizedDescription)")
            }
        }
        await transcriber.cleanup()

        func ratio(_ hits: Int, _ total: Int) -> String {
            total == 0 ? "\(hits)/0" : String(format: "%d/%d (%.0f%%)", hits, total, Double(hits) * 100 / Double(total))
        }
        let termRows = rows.filter { !$0.expectedTerms.isEmpty }
        let controlRows = rows.filter { $0.expectedTerms.isEmpty }
        let audioSeconds = rows.reduce(0) { $0 + $1.audioSeconds }
        let asrSeconds = rows.reduce(0) { $0 + $1.asrSeconds }
        let rescoreSeconds = rows.reduce(0) { $0 + $1.rescoreSeconds }
        stdout("""

        Settings: cbw \(options.settings.contextBiasWeight), minSimilarity \(options.settings.minimumSimilarity), \
        minTermLength \(options.settings.minimumTermLength), margin \(options.settings.marginSeconds)s, \
        acousticRescue \(options.settings.acousticRescue), model \(options.model), VAD \(!options.noVAD)
        Files: \(rows.count) (\(termRows.count) with expected terms, \(controlRows.count) controls)
        Changed transcripts: \(termRows.filter { $0.plain != $0.boosted }.count) term files, \
        \(controlRows.filter { $0.plain != $0.boosted }.count) controls
        Expected-term hits, raw ASR: plain \(ratio(termScore.plainHits, termScore.expected)), \
        boosted \(ratio(termScore.boostedHits, termScore.expected))
        Expected-term hits, after app cleanup and replacements: plain \(ratio(finalScore.plainHits, finalScore.expected)), \
        boosted \(ratio(finalScore.boostedHits, finalScore.expected))
        Unexpected term insertions: \(termScore.unexpectedInsertions) in term files, \(controlScore.unexpectedInsertions) in controls
        Nondeterministic files: \(rows.filter(\.nondeterministic).count) (runs per file: \(options.runs))
        Timing: audio \(String(format: "%.1f", audioSeconds)) s, ASR \(String(format: "%.2f", asrSeconds)) s, \
        CTC rescoring \(String(format: "%.2f", rescoreSeconds)) s \
        (\(String(format: "%.0f", audioSeconds / max(rescoreSeconds, 0.001)))x real time), \
        CTC load and setup \(String(format: "%.2f", setupSeconds)) s
        """)

        if let report = options.report {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(rows).write(to: report, options: .atomic)
        }
        return failures ? 1 : 0
    }
}
