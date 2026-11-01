import AppKit
import Foundation
import os

/// Turns a recorded annotation into its bundle: the narration transcribed with timing on a local model, then
/// `summary.md`, copied to the clipboard for an agent.
@MainActor
final class AnnotationProcessor: ObservableObject {
    static let shared = AnnotationProcessor()

    struct Environment {
        var chooseModel: @MainActor () -> (any TranscriptionModel)?
        var makeTranscriber: @MainActor (any TranscriptionModel) -> any TimedSpeechTranscribing
        var requestContext: @MainActor (any TranscriptionModel) -> TranscriptionRequestContext
        var copy: @MainActor (String) -> Void = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        var notify: @MainActor (String) -> Void = { NotificationManager.shared.showNotification(title: $0, type: .success) }
    }

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AnnotationProcessor")
    private var environment: Environment?
    private weak var recorder: AnnotationRecorder?
    private var worker: Task<Void, Never>?
    @Published private(set) var processingID: UUID?

    func configure(engine: VoiceInkEngine, recorder: AnnotationRecorder = .shared) {
        let models = engine.transcriptionModelManager
        let whisperModels = engine.whisperModelManager
        configure(
            environment: Environment(
                chooseModel: { MeetingTranscriptionModelChoice.choose(current: models.currentTranscriptionModel, usable: models.usableModels) },
                makeTranscriber: { model -> any TimedSpeechTranscribing in
                    if model.provider == .whisper {
                        return MeetingWhisperTranscriber(modelURL: { name in whisperModels.availableModels.first { $0.name == name }?.url })
                    }
                    return FluidAudioTranscriptionService()
                },
                requestContext: { [weak engine] model in
                    let context = TranscriptionRequestContext(languages: UserDefaults.standard.selectedTranscriptionLanguages, model: model)
                    guard let engine else { return context }
                    return context.withVocabulary(CustomVocabularyService.shared.loadSavedVocabulary(from: engine.modelContext))
                }
            ),
            recorder: recorder
        )
    }

    func configure(environment: Environment, recorder: AnnotationRecorder) {
        self.environment = environment
        self.recorder = recorder
        recorder.onRecorded = { [weak self] manifest in self?.process(manifest.id) }
        recorder.isProcessing = { [weak self] id in self?.processingID == id || self?.pendingIDs.contains(id) == true }
    }

    private var pendingIDs = Set<UUID>()

    /// One annotation at a time; a newer one waits for the current one.
    func process(_ id: UUID) {
        pendingIDs.insert(id)
        let previous = worker
        worker = Task { [weak self] in
            await previous?.value
            await self?.run(id)
            self?.pendingIDs.remove(id)
        }
    }

    func waitUntilIdle() async {
        while let worker {
            await worker.value
            if self.worker == worker { self.worker = nil }
        }
    }

    private func run(_ id: UUID) async {
        guard let environment, let recorder, var manifest = try? recorder.store.load(id: id) else { return }
        processingID = id
        defer { processingID = nil }
        let store = recorder.store
        if let model = environment.chooseModel() {
            let transcriber = environment.makeTranscriber(model)
            let meetingTranscriber = MeetingTranscriber(transcriber: transcriber, model: model, context: environment.requestContext(model))
            do {
                let samples = try MeetingTranscriber.readSamples(from: store.url(for: id, file: AnnotationManifest.narrationFileName))
                manifest.transcript = try await meetingTranscriber.transcribeTrack(samples).map {
                    MeetingTranscriber.meetingTime($0, timeline: manifest.narrationTimeline)
                }
                manifest.transcriptModel = model.name
            } catch {
                logger.error("Annotation narration transcription failed: \(error, privacy: .public)")
                manifest.failure = error.localizedDescription
            }
            await transcriber.releaseResources()
        } else {
            manifest.failure = TimedTranscriptionError.unsupportedModel.localizedDescription
        }

        // The bundle can be trashed while its narration transcribes; then nothing is written or copied.
        guard FileManager.default.fileExists(atPath: store.directory(for: id).path) else {
            logger.notice("Annotation was removed during processing")
            return
        }
        let summary = AnnotationSummary.render(manifest, folder: store.directory(for: id))
        do {
            let url = store.url(for: id, file: AnnotationManifest.summaryFileName)
            try Data(summary.utf8).write(to: url, options: [.atomic])
            store.protect(url)
            manifest.status = .ready
            try store.save(manifest)
        } catch {
            logger.error("Could not write the annotation bundle: \(error, privacy: .public)")
            manifest.status = .failed
            manifest.failure = error.localizedDescription
            recorder.update(manifest)
            return
        }
        recorder.reload()
        environment.copy(summary)
        environment.notify(String(localized: "Annotation copied for your agent"))
    }
}

/// `summary.md`: what an agent reads first. It names the bundle's folder, so a local agent can open its files.
enum AnnotationSummary {
    static func render(_ manifest: AnnotationManifest, folder: URL, locale: Locale = .current) -> String {
        var lines = [
            "# \(String(localized: "Annotation")) · \(manifest.createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale)))",
            "",
            String(format: String(localized: "A %@ screen recording with spoken narration, in %@."), MeetingMarkdown.timestamp(manifest.duration), folder.path),
            "",
            "- `\(AnnotationManifest.videoFileName)`: \(String(localized: "the screen recording"))",
            "- `\(AnnotationManifest.narrationFileName)`: \(String(localized: "the narration audio"))",
            "- `\(AnnotationManifest.fileName)`: \(String(localized: "timestamps and the transcript with word times"))",
            "",
            "## \(String(localized: "Narration"))",
            "",
        ]
        if manifest.transcript.isEmpty {
            lines.append("_\(String(localized: "No narration was transcribed."))_")
        } else {
            for segment in manifest.transcript {
                lines.append("- \(MeetingMarkdown.timestamp(segment.start)) “\(segment.text)”")
            }
        }
        let moments = manifest.marks.map { (t: $0.start, text: $0.description) }
            + manifest.events.map { event in
                let verb = switch event.kind {
                case .click: "clicked"
                case .rightClick: "right-clicked"
                case .scroll: "scrolled"
                }
                return (t: event.t, text: String(format: "\(verb) at x %.2f, y %.2f", event.x, event.y))
            }
        if !moments.isEmpty {
            lines += ["", "## \(String(localized: "Marks and clicks"))", ""]
            lines.append(String(localized: "Positions are fractions of the display, from its top-left corner."))
            lines.append("")
            for moment in moments.sorted(by: { $0.t < $1.t }) {
                lines.append("- \(MeetingMarkdown.timestamp(moment.t)) \(moment.text)")
            }
        }
        if let failure = manifest.narrationFailure {
            lines += ["", "_\(String(format: String(localized: "The narration recording failed (%@), so it may be incomplete."), failure))_"]
        }
        if let failure = manifest.failure {
            lines += ["", "_\(failure)_"]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
