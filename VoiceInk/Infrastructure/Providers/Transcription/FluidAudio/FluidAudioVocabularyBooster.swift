import FluidAudio
import Foundation
import SwiftData
import os

protocol VocabularyBoostRescoring: Sendable {
    func prepare() async throws
    func rescore(
        text: String, tokenTimings: [TokenTiming], audioSamples: [Float],
        terms: [VocabularyBoostTerm], settings: VocabularyBoostSettings
    ) async throws -> VocabularyBoostResult
    func release() async
}

/// Keeps the CTC models and the rescorer for the current vocabulary across recordings, like the
/// service's cached ASR models. The rescorer is rebuilt when the terms or settings change.
actor FluidAudioVocabularyBooster: VocabularyBoostRescoring {
    private struct Load {
        let id: UUID
        let task: Task<CtcModels, Error>
    }

    private let directory: URL
    private var models: CtcModels?
    private var loading: Load?
    private var rescorer: ParakeetVocabularyRescorer?

    init(directory: URL = ParakeetCTCModel.defaultDirectory) {
        self.directory = directory
    }

    func prepare() async throws {
        _ = try await loadedModels()
    }

    func rescore(
        text: String, tokenTimings: [TokenTiming], audioSamples: [Float],
        terms: [VocabularyBoostTerm], settings: VocabularyBoostSettings
    ) async throws -> VocabularyBoostResult {
        let models = try await loadedModels()
        let current: ParakeetVocabularyRescorer
        if let rescorer, rescorer.terms == terms, rescorer.settings == settings {
            current = rescorer
        } else {
            current = try await ParakeetVocabularyRescorer(
                models: models, modelDirectory: directory, terms: terms, settings: settings
            )
            rescorer = current
        }
        return try await current.rescore(text: text, tokenTimings: tokenTimings, audioSamples: audioSamples)
    }

    func release() {
        loading?.task.cancel()
        loading = nil
        models = nil
        rescorer = nil
    }

    private func loadedModels() async throws -> CtcModels {
        // A deleted model must not keep serving from memory-mapped bundles.
        guard ParakeetCTCModel.isInstalled(at: directory) else {
            release()
            throw VocabularyBoostError.modelNotInstalled
        }
        if let models { return models }

        let load: Load
        if let loading {
            load = loading
        } else {
            let directory = directory
            load = Load(id: UUID(), task: Task { try await ParakeetCTCModel.load(from: directory) })
            loading = load
        }
        let result = await load.task.result
        if loading?.id == load.id {
            loading = nil
            if case .success(let loaded) = result { models = loaded }
        }
        return try result.get()
    }
}

/// Opt-in CTC vocabulary rescoring for the final Parakeet batch transcript.
struct ParakeetVocabularyBoost: Sendable {
    static let enabledKey = "IsParakeetVocabularyBoostEnabled"
    static let disabled = ParakeetVocabularyBoost(isEnabled: { false }, terms: { [] }, rescorer: FluidAudioVocabularyBooster())

    let isEnabled: @Sendable () -> Bool
    let terms: @MainActor @Sendable () -> [VocabularyBoostTerm]
    let rescorer: any VocabularyBoostRescoring
    var settings = VocabularyBoostSettings.conservative
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "ParakeetVocabularyBoost")

    init(
        isEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: enabledKey) },
        terms: @escaping @MainActor @Sendable () -> [VocabularyBoostTerm],
        rescorer: any VocabularyBoostRescoring = FluidAudioVocabularyBooster()
    ) {
        self.isEnabled = isEnabled
        self.terms = terms
        self.rescorer = rescorer
    }

    static func dictionary(in modelContext: ModelContext) -> ParakeetVocabularyBoost {
        ParakeetVocabularyBoost(terms: { dictionaryTerms(in: modelContext) })
    }

    @MainActor
    static func dictionaryTerms(
        in modelContext: ModelContext, settings: VocabularyBoostSettings = .conservative
    ) -> [VocabularyBoostTerm] {
        let words = (try? modelContext.fetch(FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)]))) ?? []
        let replacements = (try? modelContext.fetch(FetchDescriptor<WordReplacement>())) ?? []
        return VocabularyBoostTerms.make(
            vocabulary: words.map(\.word),
            replacements: replacements.map {
                VocabularyBoostReplacementRule(
                    sources: WordReplacementVariants.parse($0.originalText), replacement: $0.replacementText
                )
            },
            settings: settings
        )
    }

    /// Loads the installed CTC model ahead of transcription; never downloads it.
    func prepare() async {
        guard isEnabled() else {
            await rescorer.release()
            return
        }
        do {
            try await rescorer.prepare()
        } catch {
            logger.notice("Vocabulary boost preparation unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the rescored text, or `text` unchanged when boosting is off, has no terms or fails.
    func apply(to text: String, tokenTimings: [TokenTiming]?, audioSamples: [Float]) async throws -> String {
        guard isEnabled() else {
            await rescorer.release()
            return text
        }
        let terms = await terms()
        guard !terms.isEmpty, let tokenTimings, !tokenTimings.isEmpty else { return text }

        do {
            let result = try await rescorer.rescore(
                text: text, tokenTimings: tokenTimings, audioSamples: audioSamples, terms: terms, settings: settings
            )
            try Task.checkCancellation()
            logger.notice("Vocabulary boost applied \(result.replacements.count, privacy: .public) replacement(s)")
            return result.text
        } catch {
            // A shared model load canceled by release() must not cancel this transcription.
            if Task.isCancelled { throw CancellationError() }
            logger.notice("Vocabulary boost unavailable; keeping unboosted text: \(error.localizedDescription, privacy: .public)")
            return text
        }
    }
}
