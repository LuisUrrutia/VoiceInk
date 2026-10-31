import Foundation
import os

/// Transcribes recorded meetings one at a time, after Stop or when asked again, and writes each Markdown
/// transcript. Its model is a separate local instance, loaded for the job and released after it.
@MainActor
final class MeetingTranscriptionCoordinator: ObservableObject {
    static let shared = MeetingTranscriptionCoordinator()

    struct Environment {
        var chooseModel: @MainActor () -> (any TranscriptionModel)?
        var makeTranscriber: @MainActor (any TranscriptionModel) -> any TimedSpeechTranscribing
        var requestContext: @MainActor (any TranscriptionModel) -> TranscriptionRequestContext
        var isDictating: @MainActor () -> Bool
        /// The summarizer when summaries are on; nil skips the summary.
        var summarizer: @MainActor () -> (any MeetingSummarizing)? = { nil }
        var summaryDeadline: Duration = MeetingSummary.deadline
        var outputFolder: () -> URL = { MeetingSettings.outputFolder() }
        var idleSleep: IdleSleepPrevention = .shared
        var dictationPollInterval: Duration = .milliseconds(250)
    }

    static let assertionName = "VoiceInk meeting transcription"
    /// A dictation is waited for at most this long before the next chunk runs anyway.
    static let dictationWait: Duration = .seconds(20)

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "MeetingTranscription")
    private var environment: Environment?
    private weak var recorder: MeetingRecorder?
    private var pending: [UUID] = []
    private var worker: Task<Void, Never>?

    @Published private(set) var transcribingID: UUID?

    var canTranscribe: Bool { environment?.chooseModel() != nil }

    func configure(engine: VoiceInkEngine, recorder: MeetingRecorder = .shared) {
        let whisperModels = engine.whisperModelManager
        let models = engine.transcriptionModelManager
        configure(
            environment: Environment(
                chooseModel: { MeetingTranscriptionModelChoice.choose(current: models.currentTranscriptionModel, usable: models.usableModels) },
                makeTranscriber: { model -> any TimedSpeechTranscribing in
                    if model.provider == .whisper {
                        return MeetingWhisperTranscriber(modelURL: { name in
                            whisperModels.availableModels.first { $0.name == name }?.url
                        })
                    }
                    return FluidAudioTranscriptionService()
                },
                requestContext: { [weak engine] model in
                    let context = TranscriptionRequestContext(
                        languages: UserDefaults.standard.selectedTranscriptionLanguages, model: model
                    )
                    guard let engine else { return context }
                    return context.withVocabulary(CustomVocabularyService.shared.loadSavedVocabulary(from: engine.modelContext))
                },
                isDictating: { [weak engine] in engine.map { $0.recordingState != .idle } ?? false },
                summarizer: { [weak engine] in
                    guard MeetingSettings.summarizes(), let aiService = engine?.enhancementService?.getAIService() else { return nil }
                    return EnhancementProviderSummarizer.make(aiService: aiService)
                }
            ),
            recorder: recorder
        )
    }

    func configure(environment: Environment, recorder: MeetingRecorder) {
        self.environment = environment
        self.recorder = recorder
        recorder.canTranscribe = { [weak self] in self?.canTranscribe ?? false }
        recorder.onRecorded = { [weak self] manifest in self?.enqueue(manifest.id) }
        recorder.onInterrupted = { [weak self] manifests in manifests.forEach { self?.enqueue($0.id) } }
    }

    /// Queues a meeting; a meeting already queued or transcribing is not queued twice.
    func enqueue(_ id: UUID) {
        guard transcribingID != id, !pending.contains(id) else { return }
        pending.append(id)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, let next = self.nextPending() {
                await self.transcribe(next)
            }
            self?.worker = nil
        }
    }

    /// Waits until every queued meeting is transcribed.
    func waitUntilIdle() async {
        while let worker { await worker.value }
    }

    private func nextPending() -> UUID? {
        guard !pending.isEmpty else {
            transcribingID = nil
            return nil
        }
        let next = pending.removeFirst()
        transcribingID = next
        return next
    }

    private func transcribe(_ id: UUID) async {
        guard let environment, let recorder, var manifest = try? recorder.store.load(id: id) else { return }
        guard let model = environment.chooseModel() else {
            finish(&manifest, failure: TimedTranscriptionError.unsupportedModel.localizedDescription, recorder: recorder)
            return
        }
        manifest.status = .transcribing
        manifest.failure = nil
        recorder.update(manifest)
        let hold = environment.idleSleep.begin(name: Self.assertionName)
        defer { hold.release() }

        let transcriber = environment.makeTranscriber(model)
        let meetingTranscriber = MeetingTranscriber(
            transcriber: transcriber, model: model, context: environment.requestContext(model),
            waitForDictation: { [environment] in await Self.wait(while: environment.isDictating, poll: environment.dictationPollInterval) }
        )
        do {
            let result = try await meetingTranscriber.transcribe(manifest, store: recorder.store)
            let turns = result.turns
            manifest.echoSuppressedUtterances = result.echoSuppressedUtterances
            manifest.summary = await summary(of: turns, using: environment.summarizer(), deadline: environment.summaryDeadline)
            let markdown = MeetingMarkdown.render(manifest, turns: turns, summary: manifest.summary)
            let url = try MeetingMarkdown.write(markdown, named: MeetingMarkdown.fileName(for: manifest), in: environment.outputFolder())
            if let previous = manifest.transcriptPath, previous != url.path { logger.notice("Meeting transcribed again into a new file") }
            manifest.transcriptPath = url.path
            finish(&manifest, failure: nil, recorder: recorder)
            logger.notice("Meeting transcribed id=\(id.uuidString, privacy: .public) turns=\(turns.count, privacy: .public)")
        } catch {
            logger.error("Meeting transcription failed: \(error, privacy: .public)")
            finish(&manifest, failure: error.localizedDescription, recorder: recorder)
        }
        await transcriber.releaseResources()
    }

    /// A failed or empty summary leaves the transcript without one; it never fails the transcription.
    private func summary(
        of turns: [MeetingTranscriptEntry], using summarizer: (any MeetingSummarizing)?, deadline: Duration
    ) async -> String? {
        guard let summarizer, !turns.isEmpty else { return nil }
        let excerpt = MeetingSummary.excerpt(MeetingSummary.lines(turns))
        guard let reply = await MeetingSummary.reply(from: summarizer, to: excerpt, deadline: deadline) else {
            logger.error("Meeting summary failed or missed its deadline")
            return nil
        }
        return MeetingSummary.cleaned(reply)
    }

    private func finish(_ manifest: inout MeetingManifest, failure: String?, recorder: MeetingRecorder) {
        manifest.status = failure == nil ? .transcribed : .failed
        manifest.failure = failure
        recorder.update(manifest)
    }

    private static func wait(while isDictating: @MainActor () -> Bool, poll: Duration) async {
        let deadline = ContinuousClock.now + dictationWait
        while await isDictating(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: poll)
        }
    }
}
