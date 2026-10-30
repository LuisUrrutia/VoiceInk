import FluidAudio
import Foundation

// Shared with cli/parakeet through a symlink; keep this file free of app-only types.

struct VocabularyBoostTerm: Hashable, Sendable {
    let text: String
    let aliases: [String]
}

/// Rescoring thresholds. The defaults are deliberately conservative: false replacements in
/// dictation cost more than misses (https://github.com/FluidInference/FluidAudio/issues/967).
struct VocabularyBoostSettings: Hashable, Sendable {
    var contextBiasWeight: Float = 0
    var minimumSimilarity: Float = 0.7
    var minimumTermLength = 3
    var maximumTerms = 256
    var marginSeconds = 0.5
    var acousticRescue = false

    static let conservative = VocabularyBoostSettings()
}

struct VocabularyBoostReplacementRule: Sendable {
    let sources: [String]
    let replacement: String
}

enum VocabularyBoostTerms {
    /// Builds boost terms from Dictionary vocabulary in its given order. Replacement sources whose
    /// replacement names a vocabulary term become that term's aliases.
    static func make(
        vocabulary: [String], replacements: [VocabularyBoostReplacementRule],
        settings: VocabularyBoostSettings = .conservative
    ) -> [VocabularyBoostTerm] {
        var aliasesByKey: [String: [String]] = [:]
        for rule in replacements {
            let key = key(for: rule.replacement)
            guard !key.isEmpty else { continue }
            aliasesByKey[key, default: []] += rule.sources
        }

        var seen = Set<String>()
        var terms: [VocabularyBoostTerm] = []
        for word in vocabulary {
            guard terms.count < settings.maximumTerms else { break }
            let text = normalized(word)
            let termKey = key(for: text)
            guard text.count >= settings.minimumTermLength, seen.insert(termKey).inserted else { continue }

            var aliasKeys: Set<String> = [termKey]
            let aliases = (aliasesByKey[termKey] ?? []).map(normalized).filter {
                !$0.isEmpty && aliasKeys.insert(key(for: $0)).inserted
            }
            terms.append(VocabularyBoostTerm(text: text, aliases: aliases))
        }
        return terms
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }

    private static func key(for text: String) -> String {
        (normalized(text) as NSString).folding(options: .caseInsensitive, locale: nil)
    }
}

enum ParakeetCTCModel {
    static let variant = CtcModelVariant.ctc110m
    static let tokenizerFile = "tokenizer.json"

    static var defaultDirectory: URL { CtcModels.defaultCacheDirectory(for: variant) }

    static func isInstalled(at directory: URL = defaultDirectory) -> Bool {
        CtcModels.modelsExist(at: directory)
            && FileManager.default.fileExists(atPath: directory.appendingPathComponent(tokenizerFile).path)
    }

    /// Loads installed files only; never downloads or changes FluidAudio's global offline mode.
    static func load(from directory: URL = defaultDirectory) async throws -> CtcModels {
        guard isInstalled(at: directory) else { throw VocabularyBoostError.modelNotInstalled }
        return try await CtcModels.loadDirect(from: directory, variant: variant)
    }
}

enum VocabularyBoostError: LocalizedError {
    case modelNotInstalled

    var errorDescription: String? {
        switch self {
        case .modelNotInstalled: return "The Parakeet CTC vocabulary model is not installed."
        }
    }
}

struct VocabularyBoostReplacement: Equatable, Sendable {
    let original: String
    let replacement: String
}

struct VocabularyBoostResult: Equatable, Sendable {
    let text: String
    let replacements: [VocabularyBoostReplacement]
}

/// CTC keyword spotting plus constrained rescoring for one vocabulary. FluidAudio's
/// `VocabularyBoostingSession` fixes the context-biasing weight per vocabulary size, so this
/// calls the public spotter and rescorer directly with the configured weight.
struct ParakeetVocabularyRescorer: Sendable {
    let terms: [VocabularyBoostTerm]
    let settings: VocabularyBoostSettings
    private let vocabulary: CustomVocabularyContext
    private let spotter: CtcKeywordSpotter
    private let rescorer: VocabularyRescorer

    init(models: CtcModels, modelDirectory: URL, terms: [VocabularyBoostTerm], settings: VocabularyBoostSettings) async throws {
        self.terms = terms
        self.settings = settings
        let tokenizer = try await CtcTokenizer.load(from: modelDirectory)
        let tokenized = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term.text)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term.text, aliases: term.aliases.isEmpty ? nil : term.aliases, ctcTokenIds: ids)
        }
        vocabulary = CustomVocabularyContext(
            terms: tokenized, minSimilarity: settings.minimumSimilarity, minTermLength: settings.minimumTermLength
        )
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: vocabulary,
            config: VocabularyRescorer.Config(spotterRescueEnabled: settings.acousticRescue),
            ctcModelDirectory: modelDirectory
        )
    }

    /// `tokenTimings` must use the clock of `audioSamples`: time zero is the first sample.
    func rescore(text: String, tokenTimings: [TokenTiming], audioSamples: [Float]) async throws -> VocabularyBoostResult {
        let unchanged = VocabularyBoostResult(text: text, replacements: [])
        guard !vocabulary.terms.isEmpty, !tokenTimings.isEmpty, !audioSamples.isEmpty else { return unchanged }

        let spotted = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: audioSamples, customVocabulary: vocabulary, minScore: nil
        )
        guard !spotted.logProbs.isEmpty else { return unchanged }
        let output = rescorer.ctcTokenRescore(
            transcript: text, tokenTimings: tokenTimings, logProbs: spotted.logProbs,
            frameDuration: spotted.frameDuration, cbw: settings.contextBiasWeight,
            marginSeconds: settings.marginSeconds, minSimilarity: settings.minimumSimilarity
        )
        guard output.wasModified else { return unchanged }
        return VocabularyBoostResult(
            text: output.text,
            replacements: output.replacements.compactMap { result in
                guard result.shouldReplace, let replacement = result.replacementWord else { return nil }
                return VocabularyBoostReplacement(original: result.originalWord, replacement: replacement)
            }
        )
    }
}
